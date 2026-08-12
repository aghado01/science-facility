# Replace Array with Object - Code Examples

[← Back to Replace Array with Object explanation](../Organizing%20Data.md#replace-array-with-object)

**Section:** [Organizing Data](../Organizing%20Data.md) | **Original:** [Replace Array with Object](https://refactoring.guru/replace-array-with-object)

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
String[] row = new String[2];
row[0] = "Liverpool";
row[1] = "15";
```

**After:**

```java
Performance row = new Performance();
row.setName("Liverpool");
row.setWins("15");
```

[↑ Back to top](#available-languages) | [← Back to Replace Array with Object](../Organizing%20Data.md#replace-array-with-object)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
string[] row = new string[2];
row[0] = "Liverpool";
row[1] = "15";
```

**After:**

```csharp
Performance row = new Performance();
row.SetName("Liverpool");
row.SetWins("15");
```

[↑ Back to top](#available-languages) | [← Back to Replace Array with Object](../Organizing%20Data.md#replace-array-with-object)

---

<a id="php"></a>
### PHP

**Before:**

```php
$row = [];
$row[0] = "Liverpool";
$row[1] = 15;
```

**After:**

```php
$row = new Performance;
$row->setName("Liverpool");
$row->setWins(15);
```

[↑ Back to top](#available-languages) | [← Back to Replace Array with Object](../Organizing%20Data.md#replace-array-with-object)

---

<a id="python"></a>
### Python

**Before:**

```python
row = [None * 2]
row[0] = "Liverpool"
row[1] = "15"
```

**After:**

```python
row = Performance()
row.setName("Liverpool")
row.setWins("15")
```

[↑ Back to top](#available-languages) | [← Back to Replace Array with Object](../Organizing%20Data.md#replace-array-with-object)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
let row = new Array(2);
row[0] = "Liverpool";
row[1] = "15";
```

**After:**

```typescript
let row = new Performance();
row.setName("Liverpool");
row.setWins("15");
```

[↑ Back to top](#available-languages) | [← Back to Replace Array with Object](../Organizing%20Data.md#replace-array-with-object)

---
