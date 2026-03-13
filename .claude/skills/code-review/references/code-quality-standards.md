# Code Quality Standards

## Core Principles

### 1. Readability
- **Clear naming**: Variables, functions, and classes should reveal intent
- **Small functions**: Max 20-30 lines per function
- **Single abstraction level**: Each function operates at one level of abstraction
- **Comments explain "why"**: Not "what" (the code shows what)

### 2. DRY (Don't Repeat Yourself)
- Extract common logic into shared functions
- Use composition over duplication
- If you copy-paste code, extract it

### 3. KISS (Keep It Simple)
- Prefer simple solutions over clever ones
- Avoid premature optimization
- Use standard patterns and idioms

### 4. YAGNI (You Aren't Gonna Need It)
- Don't add features "just in case"
- Build what's needed now, refactor when needed later
- Avoid speculative generality

```typescript
// ❌ Over-engineered: Adding fields "just in case"
interface User {
  id: string;
  name: string;
  email: string;
  middleName?: string;        // No requirement for this
  nickname?: string;           // No requirement for this
  preferredLanguage?: string;  // No requirement for this
  timezone?: string;           // No requirement for this
}

// ✅ Build what's needed now
interface User {
  id: string;
  name: string;
  email: string;
}
```

## Code Smells and Fixes

| Smell | Detection | Fix |
|-------|-----------|-----|
| Long function | >30 lines | Extract Function |
| Large class | Too many responsibilities | Extract Class (SRP) |
| Long parameter list | 4+ parameters | Introduce Parameter Object |
| Duplicated code | Same logic in 2+ places | Extract and Reuse |
| Primitive obsession | Primitives instead of value objects | Create Value Objects |
| Feature envy | Method uses another class's data heavily | Move Method |
| Dead code | Unused functions, variables, imports | Remove |
| Deep nesting | >3 levels of indentation | Guard Clauses, Extract |
| Magic numbers | Hardcoded numeric/string values | Named Constants |
| Switch on type | Type-checking in conditionals | Polymorphism |
| Data clump | Same group of data appears together | Extract Object |

## Best Practices

### Error Handling
- Use specific error types, not generic `catch(e)`
- Handle errors at the appropriate level
- Never silently swallow exceptions
- Provide meaningful error messages

### Null Safety
- Handle null/undefined explicitly
- Use optional chaining and nullish coalescing
- Validate at system boundaries

```typescript
// ❌ Unsafe
function getUserName(user: User) {
  return user.profile.name.first;  // crashes if profile or name is null
}

// ✅ Safe
function getUserName(user: User): string {
  return user.profile?.name?.first ?? 'Unknown';
}
```

### Immutability
- Prefer `const` over `let`
- Create new objects instead of mutating
- Use spread/destructuring for updates

```typescript
// ❌ Mutation
function addItem(cart: Cart, item: Item) {
  cart.items.push(item);        // mutates original
  cart.total += item.price;     // mutates original
  return cart;
}

// ✅ Immutable
function addItem(cart: Cart, item: Item): Cart {
  return {
    ...cart,
    items: [...cart.items, item],
    total: cart.total + item.price,
  };
}
```

### Pure Functions
- Same input → same output
- No side effects
- Easier to test and reason about

```typescript
// ❌ Impure — depends on external state
let taxRate = 0.2;
function calculateTotal(price: number) {
  return price * (1 + taxRate);  // depends on external mutable state
}

// ✅ Pure — all inputs explicit
function calculateTotal(price: number, taxRate: number): number {
  return price * (1 + taxRate);
}
```

### Value Objects (fix Primitive Obsession)

```typescript
// ❌ Primitive obsession — email is just a string everywhere
function sendEmail(to: string, subject: string) { ... }
sendEmail("not-an-email", "Hello");  // no validation

// ✅ Value object — validation at construction
class Email {
  private constructor(private readonly value: string) {}

  static create(value: string): Email {
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) {
      throw new Error(`Invalid email: ${value}`);
    }
    return new Email(value);
  }

  toString(): string { return this.value; }
}
```

## Complexity Metrics

| Cyclomatic Complexity | Risk Level | Action |
|----------------------|------------|--------|
| 1-5 | Low | OK |
| 6-10 | Moderate | Consider simplifying |
| 11-20 | High | Should refactor |
| 21+ | Very high | Must refactor |

## Review Checklist

### Readability
- [ ] Clear, descriptive names
- [ ] Functions are small and focused
- [ ] Comments explain "why", not "what"
- [ ] Consistent formatting

### Maintainability
- [ ] No code duplication
- [ ] Single responsibility per module
- [ ] Low coupling between modules
- [ ] Easy to extend

### Correctness
- [ ] Edge cases handled
- [ ] Error handling is appropriate
- [ ] Input validation at boundaries
- [ ] Tests cover critical paths

### Performance
- [ ] No unnecessary loops or computation
- [ ] Efficient data structures
- [ ] No N+1 query patterns
- [ ] Resources cleaned up properly
