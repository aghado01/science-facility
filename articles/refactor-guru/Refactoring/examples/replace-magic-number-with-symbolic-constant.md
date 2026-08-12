# Replace Magic Number with Symbolic Constant - Code Examples

[← Back to Replace Magic Number with Symbolic Constant explanation](../Organizing%20Data.md#replace-magic-number-with-symbolic-constant)

**Section:** [Organizing Data](../Organizing%20Data.md) | **Original:** [Replace Magic Number with Symbolic Constant](https://refactoring.guru/replace-magic-number-with-symbolic-constant)

---

### Available Languages

- [Java](#java)
- [C#](#csharp)
- [PHP](#php)
- [Python](#python)
- [TypeScript](#typescript)

---

<a id="java"></a>
### Java

**Before:**

```java
double potentialEnergy(double mass, double height) {
  return mass * height * 9.81;
}
```

**After:**

```java
static final double GRAVITATIONAL_CONSTANT = 9.81;

double potentialEnergy(double mass, double height) {
  return mass * height * GRAVITATIONAL_CONSTANT;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Magic Number with Symbolic Constant](../Organizing%20Data.md#replace-magic-number-with-symbolic-constant)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
double PotentialEnergy(double mass, double height) 
{
  return mass * height * 9.81;
}
```

**After:**

```csharp
const double GRAVITATIONAL_CONSTANT = 9.81;

double PotentialEnergy(double mass, double height) 
{
  return mass * height * GRAVITATIONAL_CONSTANT;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Magic Number with Symbolic Constant](../Organizing%20Data.md#replace-magic-number-with-symbolic-constant)

---

<a id="php"></a>
### PHP

**Before:**

```php
function potentialEnergy($mass, $height) {
  return $mass * $height * 9.81;
}
```

**After:**

```php
define("GRAVITATIONAL_CONSTANT", 9.81);

function potentialEnergy($mass, $height) {
  return $mass * $height * GRAVITATIONAL_CONSTANT;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Magic Number with Symbolic Constant](../Organizing%20Data.md#replace-magic-number-with-symbolic-constant)

---

<a id="python"></a>
### Python

**Before:**

```python
def potentialEnergy(mass, height):
    return mass * height * 9.81
```

**After:**

```python
GRAVITATIONAL_CONSTANT = 9.81

def potentialEnergy(mass, height):
    return mass * height * GRAVITATIONAL_CONSTANT
```

[↑ Back to top](#available-languages) | [← Back to Replace Magic Number with Symbolic Constant](../Organizing%20Data.md#replace-magic-number-with-symbolic-constant)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
potentialEnergy(mass: number, height: number): number {
  return mass * height * 9.81;
}
```

**After:**

```typescript
static const GRAVITATIONAL_CONSTANT = 9.81;

potentialEnergy(mass: number, height: number): number {
  return mass * height * GRAVITATIONAL_CONSTANT;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Magic Number with Symbolic Constant](../Organizing%20Data.md#replace-magic-number-with-symbolic-constant)

---
