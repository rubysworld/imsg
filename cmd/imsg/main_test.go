package main

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"io"
	"os"
	"strings"
	"testing"
	"time"
)

const appleEpochOffset = 978307200

func appleFromTime(t time.Time) int64 {
	return t.Add(-time.Duration(appleEpochOffset) * time.Second).UnixNano()
}

func buildTempDB(t *testing.T) string {
	t.Helper()
	dbfile := t.TempDir() + "/chat.db"
	dbConn, err := sql.Open("sqlite", "file:"+dbfile)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	stmts := []string{
		`CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT, service_name TEXT);`,
		`CREATE TABLE message (ROWID INTEGER PRIMARY KEY, handle_id INTEGER, text TEXT, date INTEGER, is_from_me INTEGER, service TEXT);`,
		`CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);`,
		`CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);`,
		`CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);`,
	}
	for _, s := range stmts {
		if _, err := dbConn.Exec(s); err != nil {
			t.Fatalf("exec %s: %v", s, err)
		}
	}

	now := time.Now().UTC()
	// seed data
	_, _ = dbConn.Exec(`INSERT INTO chat(ROWID, chat_identifier, display_name, service_name) VALUES (1, '+123', 'Test Chat', 'iMessage')`)
	_, _ = dbConn.Exec(`INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, 'Me')`)

	msgs := []struct {
		id     int
		handle int
		text   string
		fromMe bool
		date   time.Time
	}{
		{1, 1, "hello", false, now.Add(-5 * time.Minute)},
		{2, 2, "hi back", true, now.Add(-4 * time.Minute)},
	}
	for _, m := range msgs {
		if _, err := dbConn.Exec(`INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service) VALUES (?,?,?,?,?,?)`, m.id, m.handle, m.text, appleFromTime(m.date), boolToInt(m.fromMe), "iMessage"); err != nil {
			t.Fatalf("insert message: %v", err)
		}
		if _, err := dbConn.Exec(`INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)`, m.id); err != nil {
			t.Fatalf("insert cmj: %v", err)
		}
	}
	_ = dbConn.Close()
	return dbfile
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func TestChatsCommandPrintsChats(t *testing.T) {
	dbPath = buildTempDB(t)
	cmd := newChatsCmd()
	cmd.SetContext(context.Background())
	cmd.SetArgs([]string{"--limit", "5"})

	out := captureOutput(t, func() {
		_ = cmd.Execute()
	})
	if strings.TrimSpace(out) == "" {
		t.Fatalf("expected output, got empty")
	}
	if !strings.Contains(out, "Test Chat") {
		t.Fatalf("expected chat name in output, got %s", out)
	}
}

func TestChatsCommandPrintsJSON(t *testing.T) {
	dbPath = buildTempDB(t)
	cmd := newChatsCmd()
	cmd.SetContext(context.Background())
	cmd.SetArgs([]string{"--limit", "5", "--json"})

	out := captureOutput(t, func() {
		if err := cmd.Execute(); err != nil {
			t.Fatalf("execute chats: %v", err)
		}
	})

	scanner := bufio.NewScanner(strings.NewReader(out))
	if !scanner.Scan() {
		t.Fatalf("expected JSON output, got empty")
	}
	var payload map[string]any
	if err := json.Unmarshal(scanner.Bytes(), &payload); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if payload["name"] != "Test Chat" {
		t.Fatalf("expected name, got %#v", payload["name"])
	}
	if payload["identifier"] != "+123" {
		t.Fatalf("expected identifier, got %#v", payload["identifier"])
	}
	if payload["last_message_at"] == "" {
		t.Fatalf("expected last_message_at, got empty")
	}
}

func TestHistoryCommandRequiresChatID(t *testing.T) {
	dbPath = buildTempDB(t)
	cmd := newHistoryCmd()
	cmd.SetContext(context.Background())
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error when chat-id missing")
	}
}

func TestHistoryCommandPrintsMessages(t *testing.T) {
	dbPath = buildTempDB(t)
	cmd := newHistoryCmd()
	cmd.SetContext(context.Background())
	cmd.SetArgs([]string{"--chat-id", "1", "--limit", "10"})

	out := captureOutput(t, func() {
		if err := cmd.Execute(); err != nil {
			t.Fatalf("execute history: %v", err)
		}
	})
	if !strings.Contains(out, "hello") || !strings.Contains(out, "hi back") {
		t.Fatalf("missing messages in output: %s", out)
	}
}

func captureOutput(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	os.Stdout = w
	fn()
	_ = w.Close()
	os.Stdout = old

	outBytes, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return string(outBytes)
}
