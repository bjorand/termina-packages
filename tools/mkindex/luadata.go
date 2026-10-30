package main

import (
	"fmt"
	"strconv"
	"strings"
)

// Minimal reader for "Lua data": return { key = value, ... } with strings,
// integers, booleans and nested tables. The package.lua manifests and the
// published index use nothing else: a manifest that contains code (functions,
// calls, concatenations) is rejected.

type luaTable struct {
	Array []any
	Hash  map[string]any
}

type parser struct {
	src  string
	pos  int
	name string
}

func parseLuaData(name, src string) (*luaTable, error) {
	p := &parser{src: src, name: name}
	p.skip()
	if !p.word("return") {
		return nil, p.errorf("\"return { ... }\" expected")
	}
	p.skip()
	v, err := p.value()
	if err != nil {
		return nil, err
	}
	t, ok := v.(*luaTable)
	if !ok {
		return nil, p.errorf("a table is expected after return")
	}
	p.skip()
	if p.pos < len(p.src) && p.src[p.pos] == ';' {
		p.pos++
		p.skip()
	}
	if p.pos != len(p.src) {
		return nil, p.errorf("unexpected text after the table")
	}
	return t, nil
}

func (p *parser) errorf(format string, args ...any) error {
	line := 1 + strings.Count(p.src[:p.pos], "\n")
	return fmt.Errorf("%s:%d: %s", p.name, line, fmt.Sprintf(format, args...))
}

// skip skips whitespace and comments (-- line, --[[ block ]]).
func (p *parser) skip() {
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		switch {
		case c == ' ' || c == '\t' || c == '\r' || c == '\n':
			p.pos++
		case strings.HasPrefix(p.src[p.pos:], "--"):
			p.pos += 2
			if open, level := longBracket(p.src[p.pos:]); open > 0 {
				end := strings.Index(p.src[p.pos+open:], "]"+strings.Repeat("=", level)+"]")
				if end < 0 {
					p.pos = len(p.src)
					return
				}
				p.pos += open + end + level + 2
				continue
			}
			for p.pos < len(p.src) && p.src[p.pos] != '\n' {
				p.pos++
			}
		default:
			return
		}
	}
}

// longBracket recognizes "[[" or "[==[": length of the opening and level.
func longBracket(s string) (int, int) {
	if !strings.HasPrefix(s, "[") {
		return 0, 0
	}
	i := 1
	for i < len(s) && s[i] == '=' {
		i++
	}
	if i < len(s) && s[i] == '[' {
		return i + 1, i - 1
	}
	return 0, 0
}

func isIdent(c byte, first bool) bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || !first && c >= '0' && c <= '9'
}

func (p *parser) ident() string {
	start := p.pos
	for p.pos < len(p.src) && isIdent(p.src[p.pos], p.pos == start) {
		p.pos++
	}
	return p.src[start:p.pos]
}

func (p *parser) word(w string) bool {
	save := p.pos
	if p.ident() == w {
		return true
	}
	p.pos = save
	return false
}

func (p *parser) value() (any, error) {
	if p.pos >= len(p.src) {
		return nil, p.errorf("value expected")
	}
	c := p.src[p.pos]
	switch {
	case c == '{':
		return p.table()
	case c == '"' || c == '\'':
		return p.str()
	case c == '[':
		if open, level := longBracket(p.src[p.pos:]); open > 0 {
			end := strings.Index(p.src[p.pos+open:], "]"+strings.Repeat("=", level)+"]")
			if end < 0 {
				return nil, p.errorf("unfinished long string")
			}
			s := p.src[p.pos+open : p.pos+open+end]
			s = strings.TrimPrefix(strings.TrimPrefix(s, "\r"), "\n")
			p.pos += open + end + level + 2
			return s, nil
		}
	case c == '-' || c >= '0' && c <= '9':
		start := p.pos
		p.pos++
		for p.pos < len(p.src) && p.src[p.pos] >= '0' && p.src[p.pos] <= '9' {
			p.pos++
		}
		n, err := strconv.ParseInt(p.src[start:p.pos], 10, 64)
		if err != nil {
			return nil, p.errorf("invalid number")
		}
		return n, nil
	case isIdent(c, true):
		switch w := p.ident(); w {
		case "true":
			return true, nil
		case "false":
			return false, nil
		default:
			return nil, p.errorf("\"%s\": only data is allowed (strings, numbers, tables)", w)
		}
	}
	return nil, p.errorf("unexpected value \"%c\"", c)
}

func (p *parser) str() (string, error) {
	q := p.src[p.pos]
	p.pos++
	var b strings.Builder
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		p.pos++
		switch {
		case c == q:
			return b.String(), nil
		case c == '\n':
			return "", p.errorf("unfinished string")
		case c == '\\':
			if p.pos >= len(p.src) {
				return "", p.errorf("unfinished string")
			}
			e := p.src[p.pos]
			p.pos++
			switch e {
			case 'n':
				b.WriteByte('\n')
			case 't':
				b.WriteByte('\t')
			case 'r':
				b.WriteByte('\r')
			case '\\', '"', '\'':
				b.WriteByte(e)
			case '\n':
				b.WriteByte('\n')
			default:
				if e >= '0' && e <= '9' {
					start := p.pos - 1
					for p.pos < len(p.src) && p.pos-start < 3 && p.src[p.pos] >= '0' && p.src[p.pos] <= '9' {
						p.pos++
					}
					n, _ := strconv.Atoi(p.src[start:p.pos])
					if n > 255 {
						return "", p.errorf("invalid escape")
					}
					b.WriteByte(byte(n))
					continue
				}
				return "", p.errorf("unsupported escape \\%c", e)
			}
		default:
			b.WriteByte(c)
		}
	}
	return "", p.errorf("unfinished string")
}

func (p *parser) table() (*luaTable, error) {
	p.pos++ // {
	t := &luaTable{Hash: map[string]any{}}
	for {
		p.skip()
		if p.pos >= len(p.src) {
			return nil, p.errorf("\"}\" missing")
		}
		if p.src[p.pos] == '}' {
			p.pos++
			return t, nil
		}
		var key string
		hasKey := false
		save := p.pos
		if p.src[p.pos] == '[' {
			if open, _ := longBracket(p.src[p.pos:]); open == 0 {
				p.pos++
				p.skip()
				k, err := p.value()
				if err != nil {
					return nil, err
				}
				ks, ok := k.(string)
				if !ok {
					return nil, p.errorf("only string keys are allowed")
				}
				p.skip()
				if p.pos >= len(p.src) || p.src[p.pos] != ']' {
					return nil, p.errorf("\"]\" expected")
				}
				p.pos++
				p.skip()
				if p.pos >= len(p.src) || p.src[p.pos] != '=' {
					return nil, p.errorf("\"=\" expected")
				}
				p.pos++
				key, hasKey = ks, true
			}
		} else if isIdent(p.src[p.pos], true) {
			id := p.ident()
			p.skip()
			if p.pos < len(p.src) && p.src[p.pos] == '=' && !strings.HasPrefix(p.src[p.pos:], "==") {
				p.pos++
				key, hasKey = id, true
			} else {
				p.pos = save
			}
		}
		p.skip()
		v, err := p.value()
		if err != nil {
			return nil, err
		}
		if hasKey {
			if _, dup := t.Hash[key]; dup {
				return nil, p.errorf("duplicate key \"%s\"", key)
			}
			t.Hash[key] = v
		} else {
			t.Array = append(t.Array, v)
		}
		p.skip()
		if p.pos < len(p.src) && (p.src[p.pos] == ',' || p.src[p.pos] == ';') {
			p.pos++
		} else if p.pos < len(p.src) && p.src[p.pos] != '}' {
			return nil, p.errorf("\",\" or \"}\" expected")
		}
	}
}

// ------------------------------------------------------------------ writing

// luaString writes a quoted Lua string, readable by the device as well as by
// parseLuaData.
func luaString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case c == '\n':
			b.WriteString(`\n`)
		case c < 0x20 || c == 0x7f:
			fmt.Fprintf(&b, `\%03d`, c)
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}
