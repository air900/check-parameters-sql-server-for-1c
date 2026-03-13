# Architecture Principles

## SOLID Principles

### Single Responsibility (SRP)
Each module/class should have one reason to change. If a module handles both data validation AND database access, split it.

### Open/Closed (OCP)
Open for extension, closed for modification. Use interfaces, strategy pattern, or composition to add behavior without changing existing code.

### Liskov Substitution (LSP)
Subtypes must be substitutable for their base types without breaking the program. If a subclass overrides a method with different behavior, the hierarchy is wrong.

### Interface Segregation (ISP)
Many specific interfaces are better than one general-purpose interface. Clients shouldn't depend on methods they don't use.

### Dependency Inversion (DIP)
High-level modules should not depend on low-level modules. Both should depend on abstractions. Inject dependencies rather than hard-coding them.

```typescript
// ❌ Hard-coded dependency
class UserService {
  private db = new PostgresDatabase();  // tightly coupled
  async getUser(id: string) {
    return this.db.query('SELECT * FROM users WHERE id = $1', [id]);
  }
}

// ✅ Dependency injection
interface UserRepository {
  findById(id: string): Promise<User | null>;
}

class UserService {
  constructor(private readonly userRepo: UserRepository) {}  // injected
  async getUser(id: string) {
    return this.userRepo.findById(id);
  }
}
```

## Layered Architecture

```
Presentation Layer    — UI, Views, API routes, Controllers
Application Layer     — Use Cases, Orchestration, DTOs
Domain Layer          — Business Logic, Entities, Value Objects
Data Layer            — Repositories, Data Access, Storage
Infrastructure Layer  — External Services, I/O, Messaging
```

**Rule:** Each layer depends only on layers below it. Never import from a higher layer.

## Design Patterns

### Repository Pattern
Abstract data access behind an interface. Business logic calls `userRepository.findById(id)` without knowing if it's SQL, MongoDB, or in-memory.

### Service Pattern
Encapsulate business logic in service classes. Controllers delegate to services, services delegate to repositories.

### Factory Pattern
Create objects without specifying exact classes. Useful when the creation logic is complex or depends on configuration.

### Strategy Pattern
Encapsulate algorithms behind a common interface, making them interchangeable. Use when you have multiple ways to do something (e.g., payment providers, notification channels).

## Code Organization

### Feature-Based (recommended for large apps)
```
src/features/
  auth/
    components/
    services/
    types.ts
    index.ts
  payments/
    components/
    services/
    types.ts
    index.ts
```

### Layer-Based (for smaller apps)
```
src/
  controllers/
  services/
  repositories/
  models/
  utils/
```

## Error Handling Strategy

```typescript
// ❌ Generic catch-all
try {
  await processPayment(order);
} catch (e) {
  console.log("Error");  // swallowed, no context
}

// ✅ Typed errors with centralized handling
class PaymentError extends Error {
  constructor(
    message: string,
    public readonly code: 'INSUFFICIENT_FUNDS' | 'PROVIDER_DOWN' | 'INVALID_CARD',
    public readonly retryable: boolean,
  ) {
    super(message);
    this.name = 'PaymentError';
  }
}

try {
  await processPayment(order);
} catch (error) {
  if (error instanceof PaymentError && error.retryable) {
    await scheduleRetry(order);
  } else {
    throw error;  // let it propagate to error boundary
  }
}
```

## Configuration Management

```typescript
// ❌ Scattered config
const API_URL = "https://api.example.com";  // hardcoded in service
const TIMEOUT = 5000;                        // hardcoded in another file

// ✅ Centralized config
// config/index.ts
export const config = {
  api: {
    url: process.env.API_URL ?? 'http://localhost:3000',
    timeout: Number(process.env.API_TIMEOUT ?? 5000),
  },
  auth: {
    sessionTtl: Number(process.env.SESSION_TTL ?? 3600),
  },
} as const;
```

## Anti-Patterns

| Anti-Pattern | Symptom | Fix |
|-------------|---------|-----|
| God Object | One class/module does everything | Split by responsibility |
| Big Ball of Mud | No clear boundaries | Define modules with clear interfaces |
| Circular Dependencies | A imports B imports A | Dependency inversion, extract shared interface |
| Leaky Abstraction | Implementation details leak through interface | Proper encapsulation |
| Spaghetti Code | Complex, tangled control flow | Refactor into clear, linear flow |
| Golden Hammer | Using one tool/pattern for everything | Choose the right pattern for each problem |
| Premature Optimization | Optimizing before measuring | Measure first, optimize bottlenecks only |

## Performance Principles

### Data Access
- Index frequently queried columns
- Use pagination for large result sets
- Use connection pooling
- Avoid N+1 query patterns (fetch related data in bulk)

### Caching
- Cache expensive computations
- Use appropriate TTLs
- Invalidate cache on data changes
- Consider cache stampede prevention

### Async Operations
- Use async/await for I/O-bound work
- Don't block the event loop
- Use worker threads for CPU-intensive tasks
- Implement proper cleanup (close connections, clear timers)

## Testing Strategy

```
         /  E2E Tests  \          — Few, slow, high confidence
        / Integration    \        — Some, moderate speed
       /   Unit Tests      \      — Many, fast, focused
```

- **Unit:** Test business logic in isolation
- **Integration:** Test module interactions
- **E2E:** Test critical user flows

## Architecture Review Checklist

### Structure
- [ ] Clear separation of concerns
- [ ] Logical folder/module organization
- [ ] Well-defined module boundaries
- [ ] Dependencies flow in one direction

### Dependencies
- [ ] No circular dependencies
- [ ] Dependency injection used
- [ ] Abstractions over concretions
- [ ] External services behind interfaces

### Scalability
- [ ] Stateless where possible
- [ ] Efficient data access patterns
- [ ] Appropriate caching
- [ ] Handles expected load

### Maintainability
- [ ] Self-documenting code
- [ ] Consistent naming conventions
- [ ] Easy to add new features
- [ ] Low coupling, high cohesion

### Testability
- [ ] Business logic isolated from I/O
- [ ] Dependencies injectable/mockable
- [ ] Adequate test coverage
- [ ] Tests run fast
