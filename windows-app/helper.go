package main

// The helper is the part of PC Power that runs in the signed-in user's session: the tray icon and
// window, plus this loop, which tells the core what the session is doing (is anyone using the PC, is
// something full-screen) and carries out actions that only work from inside a session.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"
)

var helperDir string // where the running core wrote its local key

var helperClient = &http.Client{Timeout: 4 * time.Second}

// localCall calls the core's local API with the key from the key file.
func localCall(method, path string, body any) (map[string]any, error) {
	port, key := readKeyFile(helperDir)
	if key == "" {
		return nil, errors.New("PC Power is not running, or this account is not allowed to control it")
	}
	var buf bytes.Buffer
	if body != nil {
		json.NewEncoder(&buf).Encode(body)
	}
	req, err := http.NewRequest(method, fmt.Sprintf("http://127.0.0.1:%d%s", port, path), &buf)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-PCPower", "1")
	req.Header.Set("X-PCPower-Key", key)
	req.Header.Set("Content-Type", "application/json")
	res, err := helperClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	out := map[string]any{}
	json.NewDecoder(res.Body).Decode(&out)
	if res.StatusCode != 200 {
		return out, fmt.Errorf("%v", out["error"])
	}
	return out, nil
}

func helperLoop() {
	for {
		out, err := localCall("POST", "/api/local/presence", map[string]any{"idle": sessionIdleSeconds(), "fullscreen": sessionFullscreen()})
		if err == nil {
			if cmds, ok := out["commands"].([]any); ok {
				for _, c := range cmds {
					if name, ok := c.(string); ok {
						sessionRun(name)
					}
				}
			}
		}
		time.Sleep(3 * time.Second)
	}
}
