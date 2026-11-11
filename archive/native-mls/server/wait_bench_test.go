// #424 acceptance measurement (opt-in: RELAY_LONGPOLL_BENCH=1). 12 bots × 2
// rooms = 24 readers against one relay for a fixed window; a writer posts one
// event to a random room every ~250 ms. Compared: today's 200 ms polling
// (bot/src/session.rs POLL) vs ?wait=25000. Reported: total GET requests
// (idle request rate) and delivery latency p50/p95 (post → reader has it).
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestLongPollAcceptanceBench(t *testing.T) {
	if os.Getenv("RELAY_LONGPOLL_BENCH") != "1" {
		t.Skip("set RELAY_LONGPOLL_BENCH=1 to run the #424 measurement")
	}
	const bots, roomsPerBot = 12, 2
	window := 6 * time.Second
	for _, mode := range []struct {
		name string
		wait int // ms; 0 = plain polling every 200 ms
	}{{"poll-200ms", 0}, {"wait-25s", 25000}} {
		reqs, lat := runLongPollBench(t, bots, roomsPerBot, window, mode.wait)
		sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
		pct := func(p float64) time.Duration {
			if len(lat) == 0 {
				return 0
			}
			return lat[int(float64(len(lat)-1)*p)]
		}
		t.Logf("%-10s readers=%d window=%v GET=%d (%.1f req/s) deliveries=%d p50=%v p95=%v",
			mode.name, bots*roomsPerBot, window, reqs, float64(reqs)/window.Seconds(), len(lat), pct(0.5).Round(10*time.Microsecond), pct(0.95).Round(10*time.Microsecond))
	}
}

func runLongPollBench(t *testing.T, bots, roomsPerBot int, window time.Duration, wait int) (int64, []time.Duration) {
	_, srv := newTestRelay(t, testPolicy())
	rooms := make([]string, 0, bots*roomsPerBot)
	for i := 0; i < bots*roomsPerBot; i++ {
		room := fmt.Sprintf("b%dr%d", i/roomsPerBot, i%roomsPerBot)
		seedRoom(t, srv, room)
		rooms = append(rooms, room)
	}
	var (
		reqs    atomic.Int64
		mu      sync.Mutex
		posted  = map[string]time.Time{} // room/seq → post time
		latency []time.Duration
		stop    = make(chan struct{})
		wg      sync.WaitGroup
	)
	client := &http.Client{Timeout: 30 * time.Second}
	for i, room := range rooms {
		wg.Add(1)
		go func(room, device string) {
			defer wg.Done()
			after := int64(1)
			for {
				select {
				case <-stop:
					return
				default:
				}
				path := fmt.Sprintf("%s/v2/rooms/%s/events?device=%s&after=%d", srv.URL, room, device, after)
				if wait > 0 {
					path += fmt.Sprintf("&wait=%d", wait)
				}
				resp, err := client.Get(path)
				reqs.Add(1)
				if err != nil {
					return
				}
				raw, _ := io.ReadAll(resp.Body)
				resp.Body.Close()
				var page eventsResponse
				_ = json.Unmarshal(raw, &page)
				now := time.Now()
				for _, ev := range page.Events {
					mu.Lock()
					if at, ok := posted[fmt.Sprintf("%s/%d", room, ev.Seq)]; ok {
						latency = append(latency, now.Sub(at))
					}
					mu.Unlock()
				}
				if page.NextAfter > after {
					after = page.NextAfter
				}
				if wait == 0 {
					select {
					case <-stop:
						return
					case <-time.After(200 * time.Millisecond):
					}
				}
			}
		}(room, fmt.Sprintf("reader%d", i))
	}
	rng := rand.New(rand.NewSource(424))
	deadline := time.Now().Add(window)
	n := 0
	for time.Now().Before(deadline) {
		time.Sleep(time.Duration(200+rng.Intn(100)) * time.Millisecond)
		room := rooms[rng.Intn(len(rooms))]
		n++
		mu.Lock()
		st, raw := doJSON(t, srv, "POST", "/v2/rooms/"+room+"/events",
			postEventBody(t, "a1", fmt.Sprintf("m%d", n), "application", 0, nil, nil, []byte("x")))
		if st == http.StatusCreated {
			var r eventResponse
			_ = json.Unmarshal(raw, &r)
			posted[fmt.Sprintf("%s/%d", room, r.Seq)] = time.Now()
		}
		mu.Unlock()
	}
	time.Sleep(400 * time.Millisecond) // let the last deliveries land
	close(stop)
	// Waiting readers sit in a 25 s request; closing the server ends them.
	srv.CloseClientConnections()
	wg.Wait()
	mu.Lock()
	defer mu.Unlock()
	return reqs.Load(), append([]time.Duration(nil), latency...)
}
