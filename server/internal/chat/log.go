package chat

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	"net/http"
	"sync/atomic"
	"time"
)

// logger is the process-wide structured logger for this package. family-dev
// installs its JSON handler before serving; library users and tests keep the
// discarding default, so nothing is written unless an operator asked for it.
var logger atomic.Pointer[slog.Logger]

func init() { logger.Store(slog.New(slog.DiscardHandler)) }

// SetLogger installs the logger used for request and failure records.
func SetLogger(l *slog.Logger) {
	if l != nil {
		logger.Store(l)
	}
}

// newErrorID returns a short random identifier that ties one error response to
// its log record. It is derived from nothing request-related.
func newErrorID() string {
	var b [6]byte
	rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// Logged wraps h with one record per response: method, path (never the query
// string), status, duration and the verified actor. Tokens, cookies, request
// or response bodies, headers and attachment names are never logged.
func Logged(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		lw := &loggedWriter{ResponseWriter: w}
		h.ServeHTTP(lw, r)
		attrs := []any{"method", r.Method, "path", r.URL.Path, "status", lw.status(), "duration_ms", time.Since(start).Milliseconds()}
		// X-Family-Actor on the response is set by ServeHTTP only after the
		// identity check passed; the client-supplied request header is ignored.
		if actor := lw.Header().Get("X-Family-Actor"); actor != "" {
			attrs = append(attrs, "actor", actor)
		}
		if lw.errorID != "" {
			attrs = append(attrs, "error_id", lw.errorID)
		}
		logger.Load().Log(r.Context(), slog.LevelInfo, "request", attrs...)
	})
}

// loggedWriter records the first status written. Unwrap keeps
// http.ResponseController deadlines and Flush working through the wrapper.
// http.MaxBytesReader's connection-close hint does not see through wrappers;
// net/http still closes a connection that has more than 256 KiB unread.
type loggedWriter struct {
	http.ResponseWriter
	code    int
	errorID string
}

func (l *loggedWriter) WriteHeader(code int) {
	if l.code == 0 {
		l.code = code
	}
	l.ResponseWriter.WriteHeader(code)
}
func (l *loggedWriter) Write(b []byte) (int, error) {
	if l.code == 0 {
		l.code = http.StatusOK
	}
	return l.ResponseWriter.Write(b)
}
func (l *loggedWriter) Unwrap() http.ResponseWriter { return l.ResponseWriter }
func (l *loggedWriter) status() int {
	if l.code == 0 {
		return http.StatusOK // net/http sends 200 for a handler that wrote nothing
	}
	return l.code
}

// fail answers a store or protocol error with a stable machine-readable code
// and a random id, and logs the underlying error text under the same id. The
// id is the only correlation between the wire and the log; 5xx records are
// errors, client-side rejections stay at debug.
func fail(w http.ResponseWriter, e error) {
	status, code := statusOf(e)
	id := newErrorID()
	if l, ok := w.(*loggedWriter); ok {
		l.errorID = id
	}
	level := slog.LevelDebug
	if status >= 500 {
		level = slog.LevelError
	}
	logger.Load().Log(context.Background(), level, "request failed", "id", id, "status", status, "error", code, "cause", e.Error())
	writeJSON(w, status, struct {
		Error string `json:"error"`
		ID    string `json:"id"`
	}{code, id})
}
