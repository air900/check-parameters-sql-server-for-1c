# Refactoring Patterns

## Code Smells and Solutions

| Smell | Detection | Refactoring |
|-------|-----------|-------------|
| Long function | >30 lines | Extract Function |
| Large class | Too many responsibilities | Extract Class (SRP) |
| Long parameter list | 4+ parameters | Introduce Parameter Object |
| Duplicated code | Same logic in 2+ places | Extract and Reuse |
| Deep nesting | >3 levels of indentation | Guard Clauses, Early Returns |
| Switch on type | Type-checking conditionals | Polymorphism / Strategy |
| Feature envy | Uses another class's data heavily | Move Method |
| Data clump | Same data group appears together | Extract Object |
| Primitive obsession | Primitives instead of objects | Value Objects |
| Dead code | Unused functions/variables/imports | Remove |
| Magic numbers | Hardcoded numeric/string values | Named Constants |

## Common Refactoring Techniques

### 1. Extract Function

**Before:** 80-line method mixing concerns
```typescript
function processOrder(order: Order) {
  // 20 lines: validate order
  // 30 lines: calculate totals
  // 30 lines: send notifications
}
```

**After:** Small, focused functions
```typescript
function processOrder(order: Order) {
  validateOrder(order);
  const totals = calculateTotals(order);
  sendNotifications(order, totals);
}
```

### 2. Guard Clauses (Replace Nested Conditionals)

**Before:** Deep nesting
```typescript
function getDiscount(user: User) {
  if (user) {
    if (user.isActive) {
      if (user.isPremium) {
        return 0.2;
      } else {
        return 0.1;
      }
    }
  }
  return 0;
}
```

**After:** Flat with early returns
```typescript
function getDiscount(user: User) {
  if (!user || !user.isActive) return 0;
  if (user.isPremium) return 0.2;
  return 0.1;
}
```

### 3. Introduce Parameter Object

**Before:** Long parameter list
```typescript
function createUser(name: string, email: string, age: number, role: string, department: string) { ... }
```

**After:** Options object
```typescript
interface CreateUserOptions {
  name: string;
  email: string;
  age: number;
  role: string;
  department: string;
}

function createUser(options: CreateUserOptions) { ... }
```

### 4. Replace Conditional with Polymorphism

**Before:** Switch on type
```typescript
function getArea(shape: Shape) {
  switch (shape.type) {
    case 'circle': return Math.PI * shape.radius ** 2;
    case 'rectangle': return shape.width * shape.height;
    case 'triangle': return 0.5 * shape.base * shape.height;
  }
}
```

**After:** Polymorphic classes
```typescript
interface Shape {
  getArea(): number;
}

class Circle implements Shape {
  getArea() { return Math.PI * this.radius ** 2; }
}

class Rectangle implements Shape {
  getArea() { return this.width * this.height; }
}
```

### 5. Extract Component (React)

**Before:** 300-line monolith component
```tsx
function Dashboard() {
  // 50 lines: header logic
  // 100 lines: chart rendering
  // 80 lines: table rendering
  // 70 lines: sidebar
}
```

**After:** Focused sub-components
```tsx
function Dashboard() {
  return (
    <DashboardLayout>
      <DashboardHeader />
      <DashboardChart data={chartData} />
      <DashboardTable items={tableItems} />
      <DashboardSidebar />
    </DashboardLayout>
  );
}
```

### 6. Replace Magic Numbers with Constants

**Before:**
```typescript
if (password.length < 8) { ... }
if (retries > 3) { ... }
if (age >= 18) { ... }
```

**After:**
```typescript
const MIN_PASSWORD_LENGTH = 8;
const MAX_RETRIES = 3;
const LEGAL_AGE = 18;

if (password.length < MIN_PASSWORD_LENGTH) { ... }
if (retries > MAX_RETRIES) { ... }
if (age >= LEGAL_AGE) { ... }
```

## Refactoring Checklist

### Before
- [ ] Tests are in place and passing
- [ ] Code smell identified and categorized
- [ ] Refactoring technique chosen
- [ ] Scope is clear (don't refactor everything at once)

### During
- [ ] One small change at a time
- [ ] Run tests after each change
- [ ] Commit after each successful step
- [ ] No behavior changes

### After
- [ ] All tests still pass
- [ ] Code is more readable
- [ ] Complexity is reduced
- [ ] No new bugs introduced
- [ ] Code compiles without errors

## Complexity Metrics

| Cyclomatic Complexity | Risk | Action |
|----------------------|------|--------|
| 1-5 | Low | OK |
| 6-10 | Moderate | Consider simplifying |
| 11-20 | High | Should refactor |
| 21+ | Very high | Must refactor |
