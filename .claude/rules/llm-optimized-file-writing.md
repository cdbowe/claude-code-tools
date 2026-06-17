# LLM-Optimized File Writing

## CRITICAL RULE

**When creating or editing files intended for LLM consumption (Claude Code context files, PRDs, documentation), you MUST ALWAYS write content optimized for token efficiency and LLM processing.**

## Scope

Applies to:
- `.claude/CLAUDE.md` and `.claude/rules/*.md` files
- PRD documents (Markdown and JSON)
- Any documentation files that will be read by LLMs
- System prompts, instructions, and context files
- Custom Claude agents
- Custom Claude skills

## Optimization Principles

### 1. Structure Over Prose
- **Use tables** instead of paragraphs for comparisons, lists, or structured data
- **Use bullet lists** instead of narrative text
- **Use code blocks** for patterns and examples
- **Use headers** for clear hierarchy

### 2. Density Over Verbosity
- Remove filler words ("basically", "essentially", "in order to")
- Use imperatives ("Use X" not "You should use X")
- Combine related concepts into single entries
- Use abbreviations and shorthand where unambiguous

### 3. Examples
- Keep examples minimal but complete
- Use `✅ CORRECT` / `❌ WRONG` patterns
- Show code snippets, not descriptions of code
- One example per pattern (not 3-4 variations)

### 4. Formatting

| Pattern | Instead of | Reasoning |
|---------|------------|-----------|
| Tables | Prose paragraphs | Scannable, structured |
| Bullet lists | Numbered lists (when order doesn't matter) | Easier to parse |
| Code blocks | Inline code in sentences | Clearer patterns |
| Headers | Bold text | Hierarchical navigation |

### 5. Anti-Patterns

**Avoid:**
- Redundant explanations ("As mentioned above...")
- Conversational tone ("Let's talk about...")
- Multiple examples showing the same thing
- Long introductory paragraphs
- Restating the same rule in different sections

### 6. Content Organization

```
# Document Title

## Critical Rule (if applicable)
[Most important info first]

## When to Use / Scope

## Patterns / Rules
[Tables, lists, code blocks]

## Examples
[Minimal, illustrative]

## Anti-Patterns / Forbidden
[What NOT to do]
```

## Measurement

Before committing, ask:
1. Can any prose paragraph become a table or list?
2. Can any sentence be shortened without losing meaning?
3. Are there redundant examples?
4. Is the structure optimized for scanning?
5. Would an LLM prefer this format over narrative text?

## Example Comparison

### ❌ VERBOSE (Token-Inefficient)

"When you are working with ASP.NET WebForms controls, you should be aware that different types of controls render differently in the browser. For example, an asp:Button control will render as an HTML input element with type='submit', whereas an asp:LinkButton will actually render as an anchor tag. This is important to understand because..."

### ✅ OPTIMIZED (Token-Efficient)

| ASP.NET Control | Renders As | Text Location |
|-----------------|------------|---------------|
| `<asp:Button>` | `<input type="submit">` | `value` attr |
| `<asp:LinkButton>` | `<a>` | `innerHTML` |

## PRD-Specific Rules

- Use JSON for structured task lists (most token-efficient)
- Markdown PRDs: max 2-level headers, tables for acceptance criteria
- No motivational or background prose - implementation details only
- Examples in code blocks, not described in text

## Impact

Following these rules:
- Reduces token consumption by 40-60%
- Improves LLM parsing accuracy
- Speeds up context comprehension
- Allows more content in context windows
