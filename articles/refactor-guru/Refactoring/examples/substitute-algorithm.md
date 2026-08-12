# Substitute Algorithm - Code Examples

[← Back to Substitute Algorithm explanation](../Composing%20Methods.md#substitute-algorithm)

**Section:** [Composing Methods](../Composing%20Methods.md) | **Original:** [Substitute Algorithm](https://refactoring.guru/substitute-algorithm)

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
String foundPerson(String[] people){
  for (int i = 0; i < people.length; i++) {
    if (people[i].equals("Don")){
      return "Don";
    }
    if (people[i].equals("John")){
      return "John";
    }
    if (people[i].equals("Kent")){
      return "Kent";
    }
  }
  return "";
}
```

**After:**

```java
String foundPerson(String[] people){
  List candidates =
    Arrays.asList(new String[] {"Don", "John", "Kent"});
  for (int i=0; i < people.length; i++) {
    if (candidates.contains(people[i])) {
      return people[i];
    }
  }
  return "";
}
```

[↑ Back to top](#available-languages) | [← Back to Substitute Algorithm](../Composing%20Methods.md#substitute-algorithm)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
string FoundPerson(string[] people)
{
  for (int i = 0; i < people.Length; i++) 
  {
    if (people[i].Equals("Don"))
    {
      return "Don";
    }
    if (people[i].Equals("John"))
    {
      return "John";
    }
    if (people[i].Equals("Kent"))
    {
      return "Kent";
    }
  }
  return String.Empty;
}
```

**After:**

```csharp
string FoundPerson(string[] people)
{
  List<string> candidates = new List<string>() {"Don", "John", "Kent"};
  
  for (int i = 0; i < people.Length; i++) 
  {
    if (candidates.Contains(people[i])) 
    {
      return people[i];
    }
  }
  
  return String.Empty;
}
```

[↑ Back to top](#available-languages) | [← Back to Substitute Algorithm](../Composing%20Methods.md#substitute-algorithm)

---

<a id="php"></a>
### PHP

**Before:**

```php
function foundPerson(array $people){
  for ($i = 0; $i < count($people); $i++) {
    if ($people[$i] === "Don") {
      return "Don";
    }
    if ($people[$i] === "John") {
      return "John";
    }
    if ($people[$i] === "Kent") {
      return "Kent";
    }
  }
  return "";
}
```

**After:**

```php
function foundPerson(array $people){
  foreach (["Don", "John", "Kent"] as $needle) {
    $id = array_search($needle, $people, true);
    if ($id !== false) {
      return $people[$id];
    }
  }
  return "";
}
```

[↑ Back to top](#available-languages) | [← Back to Substitute Algorithm](../Composing%20Methods.md#substitute-algorithm)

---

<a id="python"></a>
### Python

**Before:**

```python
def foundPerson(people):
    for i in range(len(people)):
        if people[i] == "Don":
            return "Don"
        if people[i] == "John":
            return "John"
        if people[i] == "Kent":
            return "Kent"
    return ""
```

**After:**

```python
def foundPerson(people):
    candidates = ["Don", "John", "Kent"]
    return people if people in candidates else ""
```

[↑ Back to top](#available-languages) | [← Back to Substitute Algorithm](../Composing%20Methods.md#substitute-algorithm)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
foundPerson(people: string[]): string{
  for (let person of people) {
    if (person.equals("Don")){
      return "Don";
    }
    if (person.equals("John")){
      return "John";
    }
    if (person.equals("Kent")){
      return "Kent";
    }
  }
  return "";
}
```

**After:**

```typescript
foundPerson(people: string[]): string{
  let candidates = ["Don", "John", "Kent"];
  for (let person of people) {
    if (candidates.includes(person)) {
      return person;
    }
  }
  return "";
}
```

[↑ Back to top](#available-languages) | [← Back to Substitute Algorithm](../Composing%20Methods.md#substitute-algorithm)

---
