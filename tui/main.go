// Command tuninforge-tui renders the tuninforge service selection UI.
//
// Contract (keeps lib/deps.sh the single source of truth, Bash authoritative):
//   - Reads the service registry as JSON on STDIN (emitted by tuninforge_registry_json).
//   - Renders the interactive UI to STDERR (so STDOUT stays clean).
//   - On "Proceed", prints the space-separated RAW picks to STDOUT and exits 0.
//   - On cancel/quit, prints nothing and exits 1.
//
// It never resolves dependencies authoritatively — Bash re-runs tuninforge_install_order
// on the picks. The TUI computes a dependency closure only to show an accurate
// footprint/summary; that is a presentation concern, not the source of truth.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// --- Registry types (mirror tuninforge_registry_json) ----------------------------

type layer struct {
	Key   string `json:"key"`
	Title string `json:"title"`
}

type service struct {
	Name       string   `json:"name"`
	Layer      string   `json:"layer"`
	Deps       []string `json:"deps"`
	RAMMB      int      `json:"ram_mb"`
	DiskMB     int      `json:"disk_mb"`
	Watchtower bool     `json:"watchtower"`
	Networks   string   `json:"networks"`
	Desc       string   `json:"desc"`
	Default    bool     `json:"default"`
}

type registry struct {
	Layers   []layer   `json:"layers"`
	Services []service `json:"services"`
}

// --- Styles (Lip Gloss) ------------------------------------------------------

var (
	colAccent  = lipgloss.Color("39")  // cyan-blue
	colDim      = lipgloss.Color("244") // gray
	colOn       = lipgloss.Color("42")  // green
	colWarn     = lipgloss.Color("214") // amber
	colHeader   = lipgloss.Color("135") // purple
	colFg       = lipgloss.Color("252")

	stTitle    = lipgloss.NewStyle().Bold(true).Foreground(colAccent)
	stHelp     = lipgloss.NewStyle().Foreground(colDim)
	stHeader   = lipgloss.NewStyle().Bold(true).Foreground(colHeader)
	stCursor   = lipgloss.NewStyle().Bold(true).Foreground(colAccent)
	stChecked  = lipgloss.NewStyle().Foreground(colOn)
	stName     = lipgloss.NewStyle().Foreground(colFg)
	stDesc     = lipgloss.NewStyle().Foreground(colDim)
	stWarn     = lipgloss.NewStyle().Foreground(colWarn)
	stSelRow   = lipgloss.NewStyle().Bold(true)
	stBox      = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(colAccent).Padding(1, 2)
)

// --- Screens -----------------------------------------------------------------

type screen int

const (
	scFork screen = iota
	scChecklist
	scSummary
)

// A row in the checklist is either a layer header (non-selectable) or a service.
type row struct {
	isHeader bool
	title    string   // header title
	svcIndex int      // index into model.services when !isHeader
}

type model struct {
	reg registry

	scr screen

	// fork screen
	forkCursor int // 0 = QuickStart, 1 = Advanced

	// checklist screen
	rows     []row
	cursor   int            // index into rows
	checked  map[string]bool // service name -> checked

	// result
	quit    bool // true = user cancelled
	proceed bool // true = user confirmed
	picks   []string
}

func newModel(reg registry) model {
	m := model{reg: reg, scr: scFork, checked: map[string]bool{}}

	// Build checklist rows grouped by layer, in registry layer order.
	svcByLayer := map[string][]int{}
	for i, s := range reg.Services {
		svcByLayer[s.Layer] = append(svcByLayer[s.Layer], i)
		if s.Default {
			m.checked[s.Name] = true
		}
	}
	for _, l := range reg.Layers {
		idxs := svcByLayer[l.Key]
		if len(idxs) == 0 {
			continue
		}
		m.rows = append(m.rows, row{isHeader: true, title: l.Title})
		for _, i := range idxs {
			m.rows = append(m.rows, row{svcIndex: i})
		}
	}
	// Start cursor on the first selectable row.
	m.cursor = m.nextSelectable(-1, +1)
	return m
}

// nextSelectable returns the next row index in direction dir (+1/-1) that is a
// service (skips headers). Wraps within bounds; returns current if none.
func (m model) nextSelectable(from, dir int) int {
	n := len(m.rows)
	if n == 0 {
		return 0
	}
	i := from
	for k := 0; k < n; k++ {
		i += dir
		if i < 0 {
			i = n - 1
		}
		if i >= n {
			i = 0
		}
		if !m.rows[i].isHeader {
			return i
		}
	}
	return from
}

func (m model) Init() tea.Cmd { return nil }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	km, ok := msg.(tea.KeyMsg)
	if !ok {
		return m, nil
	}
	switch m.scr {
	case scFork:
		return m.updateFork(km)
	case scChecklist:
		return m.updateChecklist(km)
	case scSummary:
		return m.updateSummary(km)
	}
	return m, nil
}

func (m model) updateFork(km tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch km.String() {
	case "up", "k":
		if m.forkCursor > 0 {
			m.forkCursor--
		}
	case "down", "j":
		if m.forkCursor < 1 {
			m.forkCursor++
		}
	case "q", "ctrl+c", "esc":
		m.quit = true
		return m, tea.Quit
	case "enter":
		if m.forkCursor == 0 {
			// QuickStart: keep only defaults, straight to summary.
			for name := range m.checked {
				delete(m.checked, name)
			}
			for _, s := range m.reg.Services {
				if s.Default {
					m.checked[s.Name] = true
				}
			}
			m.scr = scSummary
		} else {
			m.scr = scChecklist
		}
	}
	return m, nil
}

func (m model) updateChecklist(km tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch km.String() {
	case "up", "k":
		m.cursor = m.nextSelectable(m.cursor, -1)
	case "down", "j":
		m.cursor = m.nextSelectable(m.cursor, +1)
	case " ":
		r := m.rows[m.cursor]
		if !r.isHeader {
			name := m.reg.Services[r.svcIndex].Name
			m.checked[name] = !m.checked[name]
		}
	case "q", "ctrl+c", "esc":
		m.quit = true
		return m, tea.Quit
	case "enter":
		m.scr = scSummary
	}
	return m, nil
}

func (m model) updateSummary(km tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch km.String() {
	case "enter", "y":
		m.proceed = true
		m.picks = m.selectedNames()
		return m, tea.Quit
	case "b", "left":
		// Back to selection (or fork if nothing to edit).
		m.scr = scChecklist
	case "q", "ctrl+c", "esc", "n":
		m.quit = true
		return m, tea.Quit
	}
	return m, nil
}

// selectedNames returns checked service names in registry order.
func (m model) selectedNames() []string {
	var out []string
	for _, s := range m.reg.Services {
		if m.checked[s.Name] {
			out = append(out, s.Name)
		}
	}
	return out
}

// closure returns selected names plus their transitive deps (registry order).
// Presentation-only: Bash re-resolves authoritatively.
func (m model) closure() []string {
	byName := map[string]service{}
	for _, s := range m.reg.Services {
		byName[s.Name] = s
	}
	inSet := map[string]bool{}
	var visit func(string)
	visit = func(n string) {
		if inSet[n] {
			return
		}
		inSet[n] = true
		for _, d := range byName[n].Deps {
			visit(d)
		}
	}
	for _, n := range m.selectedNames() {
		visit(n)
	}
	var out []string
	for _, s := range m.reg.Services {
		if inSet[s.Name] {
			out = append(out, s.Name)
		}
	}
	return out
}

func (m model) View() string {
	switch m.scr {
	case scFork:
		return m.viewFork()
	case scChecklist:
		return m.viewChecklist()
	case scSummary:
		return m.viewSummary()
	}
	return ""
}

func (m model) viewFork() string {
	var b strings.Builder
	b.WriteString(stTitle.Render("How do you want to set up tuninforge?") + "\n\n")
	opts := []struct{ name, desc string }{
		{"QuickStart", "Recommended defaults (Caddy + Portainer)"},
		{"Advanced", "Choose every service, grouped by layer"},
	}
	for i, o := range opts {
		cursor := "  "
		nameStyle := stName
		if i == m.forkCursor {
			cursor = stCursor.Render("❯ ")
			nameStyle = stSelRow.Foreground(colAccent)
		}
		b.WriteString(fmt.Sprintf("%s%s  %s\n", cursor, nameStyle.Render(o.name), stDesc.Render(o.desc)))
	}
	b.WriteString("\n" + stHelp.Render("↑/↓ move · enter confirm · q quit"))
	return stBox.Render(b.String())
}

func (m model) viewChecklist() string {
	var b strings.Builder
	b.WriteString(stTitle.Render("Select services") + "\n")
	b.WriteString(stHelp.Render("space toggle · ↑/↓ move · enter review · q quit") + "\n\n")
	for i, r := range m.rows {
		if r.isHeader {
			b.WriteString("\n" + stHeader.Render("── "+r.title+" ") + stHeader.Render(strings.Repeat("─", max(2, 40-len(r.title)))) + "\n")
			continue
		}
		s := m.reg.Services[r.svcIndex]
		box := "[ ]"
		if m.checked[s.Name] {
			box = stChecked.Render("[✓]")
		}
		cursor := "  "
		nameStyle := stName
		if i == m.cursor {
			cursor = stCursor.Render("❯ ")
			nameStyle = stSelRow.Foreground(colAccent)
		}
		b.WriteString(fmt.Sprintf("%s%s %-13s %s\n", cursor, box, nameStyle.Render(s.Name), stDesc.Render(s.Desc)))
	}
	return stBox.Render(b.String())
}

func (m model) viewSummary() string {
	var b strings.Builder
	b.WriteString(stTitle.Render("Review & confirm") + "\n\n")

	full := m.closure()
	if len(full) == 0 {
		b.WriteString(stWarn.Render("No services selected.") + "\n\n")
		b.WriteString(stHelp.Render("b back · q quit"))
		return stBox.Render(b.String())
	}

	// Group for display by layer.
	titleByKey := map[string]string{}
	for _, l := range m.reg.Layers {
		titleByKey[l.Key] = l.Title
	}
	layerByName := map[string]string{}
	var ram, disk int
	heavy := []string{}
	for _, s := range m.reg.Services {
		layerByName[s.Name] = s.Layer
	}
	grouped := map[string][]string{}
	for _, n := range full {
		grouped[layerByName[n]] = append(grouped[layerByName[n]], n)
	}
	for _, s := range m.reg.Services {
		for _, n := range full {
			if s.Name == n {
				ram += s.RAMMB
				disk += s.DiskMB
				if s.DiskMB >= 1024 {
					heavy = append(heavy, s.Name)
				}
			}
		}
	}

	b.WriteString(stName.Render("Services to install (dependencies included):") + "\n")
	for _, l := range m.reg.Layers {
		names := grouped[l.Key]
		if len(names) == 0 {
			continue
		}
		sort.Strings(names)
		b.WriteString(fmt.Sprintf("  %s  %s\n", stHeader.Render(l.Title+":"), stName.Render(strings.Join(names, " "))))
	}

	b.WriteString("\n" + stName.Render("Estimated footprint (soft — not hard limits):") + "\n")
	b.WriteString(fmt.Sprintf("  RAM  ~%s\n", humanMB(ram)))
	b.WriteString(fmt.Sprintf("  Disk ~%s\n", humanMB(disk)))
	if len(heavy) > 0 {
		b.WriteString("\n" + stWarn.Render("⚠ Disk-heavy (grows with data): "+strings.Join(heavy, ", ")) + "\n")
	}

	b.WriteString("\n" + stSelRow.Foreground(colOn).Render("[ enter/y Proceed ]") + "   " + stHelp.Render("b back · q/n cancel"))
	return stBox.Render(b.String())
}

func humanMB(mb int) string {
	if mb >= 1024 {
		return fmt.Sprintf("%d.%d GB", mb/1024, (mb%1024)*10/1024)
	}
	return fmt.Sprintf("%d MB", mb)
}

func main() {
	// The registry JSON is passed as a FILE PATH argument, NOT on stdin —
	// stdin must stay attached to the terminal so Bubble Tea can read
	// keystrokes. (Reading JSON from stdin would drain it to EOF and leave the
	// interactive UI with no input.)
	var raw []byte
	var err error
	if len(os.Args) > 1 && os.Args[1] != "-" {
		raw, err = os.ReadFile(os.Args[1])
	} else {
		// Fallback for non-interactive/testing use (e.g. piping + immediate EOF).
		raw, err = io.ReadAll(os.Stdin)
	}
	if err != nil || len(strings.TrimSpace(string(raw))) == 0 {
		fmt.Fprintln(os.Stderr, "tuninforge-tui: no registry JSON (pass a file path argument)")
		os.Exit(2)
	}
	var reg registry
	if err := json.Unmarshal(raw, &reg); err != nil {
		fmt.Fprintln(os.Stderr, "tuninforge-tui: invalid registry JSON:", err)
		os.Exit(2)
	}
	if len(reg.Services) == 0 {
		fmt.Fprintln(os.Stderr, "tuninforge-tui: registry has no services")
		os.Exit(2)
	}

	// Render the UI to STDERR; keep STDOUT for the machine-readable picks.
	// Input defaults to the controlling terminal (os.Stdin), now untouched.
	p := tea.NewProgram(newModel(reg), tea.WithOutput(os.Stderr))
	res, err := p.Run()
	if err != nil {
		fmt.Fprintln(os.Stderr, "tuninforge-tui:", err)
		os.Exit(2)
	}
	fm := res.(model)
	if fm.quit || !fm.proceed {
		os.Exit(1) // cancelled
	}
	fmt.Fprintln(os.Stdout, strings.Join(fm.picks, " "))
}
