package chat

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"mime"
	"net/http"
	"net/url"
	"runtime"
	"strconv"
	"time"
)

// uploadInitialCap is the most an upload preallocates before any body byte has
// arrived. It is deliberately far below MaxAttachment.
const uploadInitialCap = 64 * 1024

// uploadCapacity bounds the initial buffer for a declared Content-Length: the
// smaller of the declaration, uploadInitialCap and the attachment limit.
func uploadCapacity(declared int64) int {
	if declared < 0 {
		return 0
	}
	return int(min(declared, int64(min(uploadInitialCap, MaxAttachment))))
}

func singleHeader(r *http.Request, name string) (string, error) {
	v := r.Header.Values(name)
	if len(v) != 1 || v[0] == "" {
		return "", ErrInvalid
	}
	return v[0], nil
}
func (a *API) media(w http.ResponseWriter, r *http.Request, room, actor string, parts []string) {
	if r.URL.RawQuery != "" {
		fail(w, ErrInvalid)
		return
	}
	if len(parts) == 4 && r.Method == "GET" {
		e := authorize(r, func() error {
			a.store.mu.Lock()
			defer a.store.mu.Unlock()
			ms, e := a.store.listMedia(room, actor)
			if e != nil {
				return e
			}
			writeJSON(w, 200, ms)
			return nil
		})
		if e != nil {
			fail(w, e)
		}
		return
	}

	if len(parts) == 4 && r.Method == "POST" {
		a.uploadMedia(w, r, room, actor)
		return
	}
	if len(parts) == 5 && r.Method == "GET" {
		a.downloadMedia(w, r, room, actor, parts[4])
		return
	}
	http.NotFound(w, r)
}
func (a *API) uploadMedia(w http.ResponseWriter, r *http.Request, room, actor string) {
	select {
	case a.uploadSlots <- struct{}{}:
		defer func() { <-a.uploadSlots }()
	default:
		http.Error(w, "upload limit", 429)
		return
	}
	filename, e := singleHeader(r, "X-File-Name")
	if e != nil {
		fail(w, e)
		return
	}
	filename, e = url.PathUnescape(filename)
	if e != nil {
		fail(w, ErrInvalid)
		return
	}
	id, e := singleHeader(r, "X-Upload-ID")
	if e != nil {
		fail(w, e)
		return
	}
	hash, e := singleHeader(r, "X-Content-SHA256")
	if e != nil {
		fail(w, e)
		return
	}
	kind, e := singleHeader(r, "Content-Type")
	if e != nil {
		fail(w, e)
		return
	}
	var lease *mediaLease
	e = authorize(r, func() error {
		var err error
		lease, err = a.store.beginMedia(Attachment{Room: room, Actor: actor, ClientID: id, Filename: filename, MediaType: kind, Size: r.ContentLength, SHA256: hash})
		return err
	})
	if e != nil {
		fail(w, e)
		return
	}
	defer a.store.releaseMedia(lease)
	// No transaction or chat mutex is held while reading the network. Body memory
	// is bounded by the declared size and two admission slots; nothing is spooled.
	// The declared size is client input, so only a small buffer is reserved up
	// front and growth is paid as bytes actually arrive.
	body := make([]byte, 0, uploadCapacity(r.ContentLength))
	buf := make([]byte, 32*1024)
	end := time.Now().Add(30 * time.Second)
	control := http.NewResponseController(w)
	if e = control.SetWriteDeadline(end.Add(5 * time.Second)); e != nil {
		fail(w, e)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, MaxAttachment)
	for {
		if r.Context().Err() != nil {
			return
		}
		if e = authorize(r, func() error { return a.store.checkMedia(lease) }); e != nil {
			fail(w, e)
			return
		}
		deadline := time.Now().Add(2 * time.Second)
		if end.Before(deadline) {
			deadline = end
		}
		if e = control.SetReadDeadline(deadline); e != nil {
			fail(w, e)
			return
		}
		n, readErr := r.Body.Read(buf)
		if len(body)+n > int(r.ContentLength) {
			fail(w, ErrInvalid)
			return
		}
		body = append(body, buf[:n]...)
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			fail(w, ErrInvalid)
			return
		}
		if time.Now().After(end) {
			fail(w, ErrInvalid)
			return
		}
	}
	if int64(len(body)) != r.ContentLength {
		fail(w, ErrInvalid)
		return
	}
	// Request read deadline must not poison a reused connection. Response gets a
	// fresh bounded deadline after upload instead of the handler's original 5s.
	_ = control.SetReadDeadline(time.Time{})
	_ = control.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if r.Context().Err() != nil {
		return
	}
	e = authorize(r, func() error {
		m, created, err := a.store.finishMedia(lease, body)
		if err != nil {
			return err
		}
		status := 200
		if created {
			status = 201
		}
		writeJSON(w, status, m)
		return nil
	})
	if e != nil {
		fail(w, e)
	}
}

func (a *API) downloadMedia(w http.ResponseWriter, r *http.Request, room, actor, id string) {
	select {
	case a.downloadSlots <- struct{}{}:
		defer func() { <-a.downloadSlots }()
	default:
		http.Error(w, "download limit", 429)
		return
	}
	if r.Header.Get("Range") != "" {
		http.Error(w, "ranges not supported by prototype", 416)
		return
	}
	var m Attachment
	var body []byte
	var epoch uint64
	e := authorize(r, func() error { var err error; m, body, epoch, err = a.store.loadMedia(room, actor, id); return err })
	if e != nil {
		fail(w, e)
		return
	}
	digest := sha256.Sum256(body)
	if hex.EncodeToString(digest[:]) != m.SHA256 {
		fail(w, ErrIntegrity)
		return
	}
	// MIME is descriptive metadata only. No arbitrary uploaded content is served
	// inline or through an unauthenticated URL, including HTML and SVG.
	end := time.Now().Add(30 * time.Second)
	started := false
	for offset := 0; offset < len(body); {
		if r.Context().Err() != nil || time.Now().After(end) {
			return
		}
		next := offset + 32*1024
		if next > len(body) {
			next = len(body)
		}
		e = authorize(r, func() error {
			a.store.mu.Lock()
			defer a.store.mu.Unlock()
			if e = a.store.mediaAuthorized(room, actor, epoch); e != nil {
				return e
			}
			deadline := time.Now().Add(2 * time.Second)
			if end.Before(deadline) {
				deadline = end
			}
			e = http.NewResponseController(w).SetWriteDeadline(deadline)
			if e == nil && !started {
				w.Header().Set("Content-Type", "application/octet-stream")
				w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": m.Filename}))
				w.Header().Set("Content-Length", strconv.FormatInt(m.Size, 10))
				w.Header().Set("X-Content-SHA256", m.SHA256)
				w.Header().Set("Content-Security-Policy", "sandbox; default-src 'none'")
				started = true
			}
			if e == nil {
				var n int
				n, e = w.Write(body[offset:next])
				if n != next-offset && e == nil {
					e = io.ErrShortWrite
				}
			}
			if e == nil {
				e = http.NewResponseController(w).Flush()
			}
			return e
		})
		if e != nil && !started {
			fail(w, e)
		}
		if e != nil {
			return
		}
		offset = next
		// Give queued ACL changes a scheduling opportunity between bounded chunks.
		runtime.Gosched()
	}
}
