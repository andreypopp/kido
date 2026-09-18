// Package procs snapshots the process table and answers descendant queries.
package procs

import (
	"bufio"
	"bytes"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// Proc is one row of the process table.
type Proc struct {
	PID  int
	PPID int
	Comm string // basename of the executable
}

// Table is a snapshot of all processes indexed by parent.
type Table struct {
	byPID    map[int]Proc
	children map[int][]Proc
}

// Snapshot runs ps once and indexes the result.
func Snapshot() (*Table, error) {
	out, err := exec.Command("ps", "-axo", "pid=,ppid=,comm=").Output()
	if err != nil {
		return nil, err
	}
	t := &Table{byPID: map[int]Proc{}, children: map[int][]Proc{}}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 3 {
			continue
		}
		pid, err1 := strconv.Atoi(f[0])
		ppid, err2 := strconv.Atoi(f[1])
		if err1 != nil || err2 != nil {
			continue
		}
		p := Proc{PID: pid, PPID: ppid, Comm: filepath.Base(strings.Join(f[2:], " "))}
		t.byPID[pid] = p
		t.children[ppid] = append(t.children[ppid], p)
	}
	return t, sc.Err()
}

// Node is a process with its child subtree.
type Node struct {
	Proc
	Children []Node
}

// Tree returns the subtree rooted at pid (the root itself included), or nil
// if pid is not alive.
func (t *Table) Tree(pid int) *Node {
	p, ok := t.byPID[pid]
	if !ok {
		return nil
	}
	n := &Node{Proc: p}
	for _, c := range t.children[pid] {
		n.Children = append(n.Children, *t.Tree(c.PID))
	}
	return n
}

// Alive reports whether pid exists in the snapshot.
func (t *Table) Alive(pid int) bool { _, ok := t.byPID[pid]; return ok }

// FindDescendant returns the first descendant of pid whose Comm equals name.
func (t *Table) FindDescendant(pid int, name string) (Proc, bool) {
	for _, c := range t.children[pid] {
		if c.Comm == name {
			return c, true
		}
		if p, ok := t.FindDescendant(c.PID, name); ok {
			return p, true
		}
	}
	return Proc{}, false
}
