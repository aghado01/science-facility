# Introduce Foreign Method - Code Examples

[← Back to Introduce Foreign Method explanation](../Moving%20Features%20between%20Objects.md#introduce-foreign-method)

**Section:** [Moving Features between Objects](../Moving%20Features%20between%20Objects.md) | **Original:** [Introduce Foreign Method](https://refactoring.guru/introduce-foreign-method)

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
class Report {
  // ...
  void sendReport() {
    Date nextDay = new Date(previousEnd.getYear(),
      previousEnd.getMonth(), previousEnd.getDate() + 1);
    // ...
  }
}
```

**After:**

```java
class Report {
  // ...
  void sendReport() {
    Date newStart = nextDay(previousEnd);
    // ...
  }
  private static Date nextDay(Date arg) {
    return new Date(arg.getYear(), arg.getMonth(), arg.getDate() + 1);
  }
}
```

[↑ Back to top](#available-languages) | [← Back to Introduce Foreign Method](../Moving%20Features%20between%20Objects.md#introduce-foreign-method)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
class Report 
{
  // ...
  void SendReport() 
  {
    DateTime nextDay = previousEnd.AddDays(1);
    // ...
  }
}
```

**After:**

```csharp
class Report 
{
  // ...
  void SendReport() 
  {
    DateTime nextDay = NextDay(previousEnd);
    // ...
  }
  private static DateTime NextDay(DateTime date) 
  {
    return date.AddDays(1);
  }
}
```

[↑ Back to top](#available-languages) | [← Back to Introduce Foreign Method](../Moving%20Features%20between%20Objects.md#introduce-foreign-method)

---

<a id="php"></a>
### PHP

**Before:**

```php
class Report {
  // ...
  public function sendReport() {
    $previousDate = clone $this->previousDate;
    $paymentDate = $previousDate->modify("+7 days");
    // ...
  }
}
```

**After:**

```php
class Report {
  // ...
  public function sendReport() {
    $paymentDate = self::nextWeek($this->previousDate);
    // ...
  }
  /**
   * Foreign method. Should be in Date.
   */
  private static function nextWeek(DateTime $arg) {
    $previousDate = clone $arg;
    return $previousDate->modify("+7 days");
  }
}
```

[↑ Back to top](#available-languages) | [← Back to Introduce Foreign Method](../Moving%20Features%20between%20Objects.md#introduce-foreign-method)

---

<a id="python"></a>
### Python

**Before:**

```python
class Report:
    # ...
    def sendReport(self):
        nextDay = Date(self.previousEnd.getYear(),
            self.previousEnd.getMonth(), self.previousEnd.getDate() + 1)
        # ...
```

**After:**

```python
class Report:
    # ...
    def sendReport(self):
        newStart = self._nextDay(self.previousEnd)
        # ...
        
    def _nextDay(self, arg):
        return Date(arg.getYear(), arg.getMonth(), arg.getDate() + 1)
```

[↑ Back to top](#available-languages) | [← Back to Introduce Foreign Method](../Moving%20Features%20between%20Objects.md#introduce-foreign-method)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
class Report {
  // ...
  sendReport(): void {
    let nextDay: Date = new Date(previousEnd.getYear(),
      previousEnd.getMonth(), previousEnd.getDate() + 1);
    // ...
  }
}
```

**After:**

```typescript
class Report {
  // ...
  sendReport() {
    let newStart: Date = nextDay(previousEnd);
    // ...
  }
  private static nextDay(arg: Date): Date {
    return new Date(arg.getFullYear(), arg.getMonth(), arg.getDate() + 1);
  }
}
```

[↑ Back to top](#available-languages) | [← Back to Introduce Foreign Method](../Moving%20Features%20between%20Objects.md#introduce-foreign-method)

---
