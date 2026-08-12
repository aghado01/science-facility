# Extract Method - Code Examples

[← Back to Extract Method explanation](../Composing%20Methods.md#extract-method)

**Section:** [Composing Methods](../Composing%20Methods.md) | **Original:** [Extract Method](https://refactoring.guru/extract-method)

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
void printOwing() {
  printBanner();

  // Print details.
  System.out.println("name: " + name);
  System.out.println("amount: " + getOutstanding());
}
```

**After:**

```java
void printOwing() {
  printBanner();
  printDetails(getOutstanding());
}

void printDetails(double outstanding) {
  System.out.println("name: " + name);
  System.out.println("amount: " + outstanding);
}
```

[↑ Back to top](#available-languages) | [← Back to Extract Method](../Composing%20Methods.md#extract-method)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
void PrintOwing() 
{
  this.PrintBanner();

  // Print details.
  Console.WriteLine("name: " + this.name);
  Console.WriteLine("amount: " + this.GetOutstanding());
}
```

**After:**

```csharp
void PrintOwing()
{
  this.PrintBanner();
  this.PrintDetails();
}

void PrintDetails()
{
  Console.WriteLine("name: " + this.name);
  Console.WriteLine("amount: " + this.GetOutstanding());
}
```

[↑ Back to top](#available-languages) | [← Back to Extract Method](../Composing%20Methods.md#extract-method)

---

<a id="php"></a>
### PHP

**Before:**

```php
function printOwing() {
  $this->printBanner();

  // Print details.
  print("name:  " . $this->name);
  print("amount " . $this->getOutstanding());
}
```

**After:**

```php
function printOwing() {
  $this->printBanner();
  $this->printDetails($this->getOutstanding());
}

function printDetails($outstanding) {
  print("name:  " . $this->name);
  print("amount " . $outstanding);
}
```

[↑ Back to top](#available-languages) | [← Back to Extract Method](../Composing%20Methods.md#extract-method)

---

<a id="python"></a>
### Python

**Before:**

```python
def printOwing(self):
    self.printBanner()

    # print details
    print("name:", self.name)
    print("amount:", self.getOutstanding())
```

**After:**

```python
def printOwing(self):
    self.printBanner()
    self.printDetails(self.getOutstanding())

def printDetails(self, outstanding):
    print("name:", self.name)
    print("amount:", outstanding)
```

[↑ Back to top](#available-languages) | [← Back to Extract Method](../Composing%20Methods.md#extract-method)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
printOwing(): void {
  printBanner();

  // Print details.
  console.log("name: " + name);
  console.log("amount: " + getOutstanding());
}
```

**After:**

```typescript
printOwing(): void {
  printBanner();
  printDetails(getOutstanding());
}

printDetails(outstanding: number): void {
  console.log("name: " + name);
  console.log("amount: " + outstanding);
}
```

[↑ Back to top](#available-languages) | [← Back to Extract Method](../Composing%20Methods.md#extract-method)

---
