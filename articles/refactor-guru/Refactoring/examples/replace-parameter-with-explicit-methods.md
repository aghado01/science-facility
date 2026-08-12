# Replace Parameter with Explicit Methods - Code Examples

[← Back to Replace Parameter with Explicit Methods explanation](../Simplifying%20Method%20Calls.md#replace-parameter-with-explicit-methods)

**Section:** [Simplifying Method Calls](../Simplifying%20Method%20Calls.md) | **Original:** [Replace Parameter with Explicit Methods](https://refactoring.guru/replace-parameter-with-explicit-methods)

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
void setValue(String name, int value) {
  if (name.equals("height")) {
    height = value;
    return;
  }
  if (name.equals("width")) {
    width = value;
    return;
  }
  Assert.shouldNeverReachHere();
}
```

**After:**

```java
void setHeight(int arg) {
  height = arg;
}
void setWidth(int arg) {
  width = arg;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Parameter with Explicit Methods](../Simplifying%20Method%20Calls.md#replace-parameter-with-explicit-methods)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
void SetValue(string name, int value) 
{
  if (name.Equals("height")) 
  {
    height = value;
    return;
  }
  if (name.Equals("width")) 
  {
    width = value;
    return;
  }
  Assert.Fail();
}
```

**After:**

```csharp
void SetHeight(int arg) 
{
  height = arg;
}
void SetWidth(int arg) 
{
  width = arg;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Parameter with Explicit Methods](../Simplifying%20Method%20Calls.md#replace-parameter-with-explicit-methods)

---

<a id="php"></a>
### PHP

**Before:**

```php
function setValue($name, $value) {
  if ($name === "height") {
    $this->height = $value;
    return;
  }
  if ($name === "width") {
    $this->width = $value;
    return;
  }
  assert("Should never reach here");
}
```

**After:**

```php
function setHeight($arg) {
  $this->height = $arg;
}
function setWidth($arg) {
  $this->width = $arg;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Parameter with Explicit Methods](../Simplifying%20Method%20Calls.md#replace-parameter-with-explicit-methods)

---

<a id="python"></a>
### Python

**Before:**

```python
def output(self, name):
    if name == "banner"
        # Print the banner.
        # ...
    if name == "info"
        # Print the info.
        # ...
```

**After:**

```python
def outputBanner(self):
    # Print the banner.
    # ...

def outputInfo(self):
    # Print the info.
    # ...
```

[↑ Back to top](#available-languages) | [← Back to Replace Parameter with Explicit Methods](../Simplifying%20Method%20Calls.md#replace-parameter-with-explicit-methods)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
setValue(name: string, value: number): void {
  if (name.equals("height")) {
    height = value;
    return;
  }
  if (name.equals("width")) {
    width = value;
    return;
  }
  
}
```

**After:**

```typescript
setHeight(arg: number): void {
  height = arg;
}
setWidth(arg: number): number {
  width = arg;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Parameter with Explicit Methods](../Simplifying%20Method%20Calls.md#replace-parameter-with-explicit-methods)

---
