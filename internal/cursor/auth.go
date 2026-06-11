package cursor

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

func GetAccessToken() (string, error) {
	if token := strings.TrimSpace(os.Getenv("CURSOR_TAB_ACCESS_TOKEN")); token != "" {
		return token, nil
	}
	if token := strings.TrimSpace(os.Getenv("CURSOR_AUTH_TOKEN")); token != "" {
		return token, nil
	}

	if token, err := getCursorStateValue("access token", []string{"cursorAuth/accessToken"}); err == nil {
		return token, nil
	}

	for _, authPath := range cursorAgentAuthCandidates() {
		token, err := readJSONStringField(authPath, "accessToken")
		if err == nil && token != "" {
			return token, nil
		}
	}

	return "", fmt.Errorf("Cursor access token not found; checked Cursor state DB and %s", strings.Join(cursorAgentAuthCandidates(), ", "))
}

func GetMachineID() (string, error) {
	if machineID := strings.TrimSpace(os.Getenv("CURSOR_TAB_MACHINE_ID")); machineID != "" {
		return machineID, nil
	}

	keys := []string{
		"storage.serviceMachineId",
		"telemetry.machineId",
		"telemetry.devDeviceId",
	}

	if runtime.GOOS == "darwin" {
		keys = append([]string{"telemetry.macMachineId"}, keys...)
	}

	if machineID, err := getCursorStateValue("machine ID", keys); err == nil {
		return machineID, nil
	}

	if machineID, err := localMachineID(); err == nil && machineID != "" {
		return machineID, nil
	}

	return "", fmt.Errorf("could not find machine ID in Cursor state DB or local machine-id")
}

func GetCursorVersion() (string, error) {
	for _, packagePath := range cursorPackageJSONCandidates() {
		version, err := readCursorVersion(packagePath)
		if err == nil {
			return version, nil
		}
	}

	return "0.45.0", nil
}

func getCursorStateValue(label string, keys []string) (string, error) {
	dbPath, err := cursorStateDBPath()
	if err != nil {
		return "", err
	}

	for _, key := range keys {
		value, err := readCursorStateValue(dbPath, key)
		if err != nil {
			return "", fmt.Errorf("error getting %s from %s: %w", label, dbPath, err)
		}
		if value != "" {
			return value, nil
		}
	}

	return "", fmt.Errorf("could not find %s in %s", label, dbPath)
}

func readCursorStateValue(dbPath, key string) (string, error) {
	cmd := exec.Command("sqlite3", dbPath, "SELECT value FROM ItemTable WHERE key = '"+key+"';")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", err
	}

	return normalizeCursorStateValue(string(out)), nil
}

func readJSONStringField(path, key string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}

	var values map[string]string
	if err := json.Unmarshal(data, &values); err != nil {
		return "", err
	}

	return strings.TrimSpace(values[key]), nil
}

func normalizeCursorStateValue(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}

	var decoded string
	if err := json.Unmarshal([]byte(value), &decoded); err == nil {
		return strings.TrimSpace(decoded)
	}

	return value
}

func cursorAgentAuthCandidates() []string {
	homeDir, _ := os.UserHomeDir()
	var candidates []string

	if configHome := os.Getenv("XDG_CONFIG_HOME"); configHome != "" {
		candidates = append(candidates,
			filepath.Join(configHome, "cursor", "auth.json"),
			filepath.Join(configHome, "Cursor", "auth.json"),
		)
	}
	if homeDir != "" {
		candidates = append(candidates,
			filepath.Join(homeDir, ".config", "cursor", "auth.json"),
			filepath.Join(homeDir, ".config", "Cursor", "auth.json"),
		)
	}

	return dedupeStrings(candidates)
}

func cursorStateDBPath() (string, error) {
	if dbPath := os.Getenv("CURSOR_TAB_STATE_DB"); dbPath != "" {
		return dbPath, nil
	}

	candidates := cursorStateDBCandidates()
	for _, candidate := range candidates {
		if fileExists(candidate) {
			return candidate, nil
		}
	}

	if len(candidates) == 0 {
		return "", fmt.Errorf("unsupported platform %q", runtime.GOOS)
	}

	return "", fmt.Errorf("Cursor state database not found; checked %s", strings.Join(candidates, ", "))
}

func cursorStateDBCandidates() []string {
	homeDir, _ := os.UserHomeDir()

	switch runtime.GOOS {
	case "darwin":
		if homeDir == "" {
			return nil
		}
		return []string{
			filepath.Join(homeDir, "Library", "Application Support", "Cursor", "User", "globalStorage", "state.vscdb"),
		}
	case "linux":
		var candidates []string
		if configHome := os.Getenv("XDG_CONFIG_HOME"); configHome != "" {
			candidates = append(candidates, filepath.Join(configHome, "Cursor", "User", "globalStorage", "state.vscdb"))
			candidates = append(candidates, filepath.Join(configHome, "cursor", "User", "globalStorage", "state.vscdb"))
		}
		if homeDir != "" {
			candidates = append(candidates, filepath.Join(homeDir, ".config", "Cursor", "User", "globalStorage", "state.vscdb"))
			candidates = append(candidates, filepath.Join(homeDir, ".config", "cursor", "User", "globalStorage", "state.vscdb"))
		}
		return dedupeStrings(candidates)
	default:
		return nil
	}
}

func localMachineID() (string, error) {
	for _, path := range []string{"/etc/machine-id", "/var/lib/dbus/machine-id"} {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		value := strings.TrimSpace(string(data))
		if value == "" {
			continue
		}

		sum := sha256.Sum256([]byte("cursor-tab:" + value))
		return hex.EncodeToString(sum[:]), nil
	}

	return "", fmt.Errorf("local machine-id not found")
}

func cursorPackageJSONCandidates() []string {
	homeDir, _ := os.UserHomeDir()

	switch runtime.GOOS {
	case "darwin":
		return []string{"/Applications/Cursor.app/Contents/Resources/app/package.json"}
	case "linux":
		candidates := []string{
			"/usr/share/cursor/resources/app/package.json",
			"/usr/share/Cursor/resources/app/package.json",
			"/opt/cursor/resources/app/package.json",
			"/opt/Cursor/resources/app/package.json",
		}
		if homeDir != "" {
			candidates = append(candidates,
				filepath.Join(homeDir, ".local", "share", "cursor", "resources", "app", "package.json"),
				filepath.Join(homeDir, ".local", "share", "Cursor", "resources", "app", "package.json"),
			)
		}
		return candidates
	default:
		return nil
	}
}

func readCursorVersion(packagePath string) (string, error) {
	data, err := os.ReadFile(packagePath)
	if err != nil {
		return "", err
	}

	var pkg struct {
		Version string `json:"version"`
	}

	if err := json.Unmarshal(data, &pkg); err != nil {
		return "", err
	}

	if pkg.Version == "" {
		return "", fmt.Errorf("version not found in %s", packagePath)
	}

	return pkg.Version, nil
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func dedupeStrings(values []string) []string {
	seen := make(map[string]bool, len(values))
	result := make([]string, 0, len(values))

	for _, value := range values {
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		result = append(result, value)
	}

	return result
}
