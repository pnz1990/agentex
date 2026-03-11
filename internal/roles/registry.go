package roles

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"gopkg.in/yaml.v3"
)

// Registry holds all known role definitions, keyed by role name.
// It is safe for concurrent reads after loading is complete.
type Registry struct {
	mu    sync.RWMutex
	roles map[string]*Role
}

// NewRegistry creates an empty Registry.
func NewRegistry() *Registry {
	return &Registry{
		roles: make(map[string]*Role),
	}
}

// Load reads all .yaml and .yml files from the given directory and registers
// each as a Role. Files that fail to parse or validate are reported as errors.
// Loading stops on the first error encountered.
func (r *Registry) Load(dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return fmt.Errorf("reading role directory %s: %w", dir, err)
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !isYAMLFile(name) {
			continue
		}

		path := filepath.Join(dir, name)
		data, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("reading role file %s: %w", path, err)
		}

		if err := r.loadBytes(data, path); err != nil {
			return err
		}
	}

	return nil
}

// LoadFromFS reads all .yaml and .yml files from the root of the given fs.FS
// and registers each as a Role. This is useful for loading from embedded
// filesystems (embed.FS).
func (r *Registry) LoadFromFS(fsys fs.FS) error {
	entries, err := fs.ReadDir(fsys, ".")
	if err != nil {
		return fmt.Errorf("reading embedded role directory: %w", err)
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !isYAMLFile(name) {
			continue
		}

		data, err := fs.ReadFile(fsys, name)
		if err != nil {
			return fmt.Errorf("reading embedded role file %s: %w", name, err)
		}

		if err := r.loadBytes(data, name); err != nil {
			return err
		}
	}

	return nil
}

// loadBytes parses YAML bytes into a Role and registers it.
func (r *Registry) loadBytes(data []byte, source string) error {
	var role Role
	if err := yaml.Unmarshal(data, &role); err != nil {
		return fmt.Errorf("parsing role from %s: %w", source, err)
	}

	if err := role.Validate(); err != nil {
		return fmt.Errorf("validating role from %s: %w", source, err)
	}

	return r.Register(&role)
}

// Register adds a role to the registry programmatically. The role is validated
// before registration. Returns an error if the role is invalid or a role with
// the same name already exists.
func (r *Registry) Register(role *Role) error {
	if err := role.Validate(); err != nil {
		return err
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	if _, exists := r.roles[role.Name]; exists {
		return fmt.Errorf("role %q is already registered", role.Name)
	}

	r.roles[role.Name] = role
	return nil
}

// Get returns the Role with the given name, or false if not found.
func (r *Registry) Get(name string) (*Role, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	role, ok := r.roles[name]
	return role, ok
}

// List returns the names of all registered roles in sorted order.
func (r *Registry) List() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()

	names := make([]string, 0, len(r.roles))
	for name := range r.roles {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// isYAMLFile returns true if the filename ends with .yaml or .yml.
func isYAMLFile(name string) bool {
	lower := strings.ToLower(name)
	return strings.HasSuffix(lower, ".yaml") || strings.HasSuffix(lower, ".yml")
}
