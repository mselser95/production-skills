package config

// ApplyEnv overrides c from APP_ADDR, APP_WORKERS and APP_TIMEOUT. An unset or
// empty variable leaves the field alone.
func ApplyEnv(c *Config, getenv func(string) string) error {
	for _, kv := range [][2]string{
		{"addr", "APP_ADDR"},
		{"workers", "APP_WORKERS"},
		{"timeout", "APP_TIMEOUT"},
	} {
		if v := getenv(kv[1]); v != "" {
			if err := set(c, kv[0], v); err != nil {
				return err
			}
		}
	}
	return nil
}
