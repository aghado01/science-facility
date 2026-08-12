# Split Temporary Variable - Code Examples

[← Back to Split Temporary Variable explanation](../Composing%20Methods.md#split-temporary-variable)

**Section:** [Composing Methods](../Composing%20Methods.md) | **Original:** [Split Temporary Variable](https://refactoring.guru/split-temporary-variable)

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
double temp = 2 * (height + width);
System.out.println(temp);
temp = height * width;
System.out.println(temp);
```

**After:**

```java
final double perimeter = 2 * (height + width);
System.out.println(perimeter);
final double area = height * width;
System.out.println(area);
```

[↑ Back to top](#available-languages) | [← Back to Split Temporary Variable](../Composing%20Methods.md#split-temporary-variable)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
double temp = 2 * (height + width);
Console.WriteLine(temp);
temp = height * width;
Console.WriteLine(temp);
```

**After:**

```csharp
readonly double perimeter = 2 * (height + width);
Console.WriteLine(perimeter);
readonly double area = height * width;
Console.WriteLine(area);
```

[↑ Back to top](#available-languages) | [← Back to Split Temporary Variable](../Composing%20Methods.md#split-temporary-variable)

---

<a id="php"></a>
### PHP

**Before:**

```php
$temp = 2 * ($this->height + $this->width);
echo $temp;
$temp = $this->height * $this->width;
echo $temp;
```

**After:**

```php
$perimeter = 2 * ($this->height + $this->width);
echo $perimeter;
$area = $this->height * $this->width;
echo $area;
```

[↑ Back to top](#available-languages) | [← Back to Split Temporary Variable](../Composing%20Methods.md#split-temporary-variable)

---

<a id="python"></a>
### Python

**Before:**

```python
temp = 2 * (height + width)
print(temp)
temp = height * width
print(temp)
```

**After:**

```python
perimeter = 2 * (height + width)
print(perimeter)
area = height * width
print(area)
```

[↑ Back to top](#available-languages) | [← Back to Split Temporary Variable](../Composing%20Methods.md#split-temporary-variable)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
let temp = 2 * (height + width);
console.log(temp);
temp = height * width;
console.log(temp);
```

**After:**

```typescript
const perimeter = 2 * (height + width);
console.log(perimeter);
const area = height * width;
console.log(area);
```

[↑ Back to top](#available-languages) | [← Back to Split Temporary Variable](../Composing%20Methods.md#split-temporary-variable)

---
