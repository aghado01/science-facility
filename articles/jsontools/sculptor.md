# DataSculptor

DataSculptor is a powerful tool designed to sculpt your data by precisely query filtering with SQL-like expressions and projecting JSON data. It allows you to prune nested objects, filter collections based on field values, and create projections that include only specified fields, significantly reducing memory usage and improving performance in data-heavy applications.

The tool's name reflects its purpose - like a sculptor, it carefully removes the unnecessary parts to reveal the exact data shape you need.

## Core Features

## Field Projections

Extract only the specific fields you need from complex objects

## Object Filtering

Query and filter collections based on field values using a powerful SQL-like DSL

## Deep Navigation

Traverse deep into object hierarchies with intuitive dot notation

## Wildcard Support

Select all properties at a specific level with `*` notation

## Data Type Support

Works with JSON data, nested objects, collections, and arrays

## Combined Operations

Apply both query filtering and projections in a single operation

## In-place Modification

Modify objects directly for optimal performance

## Complex Query Support

Create sophisticated filters with logical operators, parentheses, and more

## Supported Filter Operators

DataSculptor supports a comprehensive set of operators in its query filtering DSL for comparing values and creating complex conditions:

## Comparison Operators

| Operator | Text Form | Symbol Form | Description | Example |
| --- | --- | --- | --- | --- |
| Equal | `eq` | `==` | Checks if values are equal | `age eq 30` or `age == 30` |
| Not Equal | `ne` | `!=` | Checks if values are not equal | `status ne 'INACTIVE'` or `status != 'INACTIVE'` |
| Less Than | `lt` | `<` | Checks if left value is less than right | `count lt 5` or `count < 5` |
| Greater Than/Equal | `gte` | `>=` | Checks if left value is greater or equal | `age gte 18` or `age >= 18` |
| Less Than/Equal | `lte` | `<=` | Checks if left value is less than or equal | `quantity lte 10` or `quantity <= 10` |

## Logical Operators

| Operator | Text Form | Symbol Form | Description | Example |
| --- | --- | --- | --- | --- |
| AND | `and` | `&&` | Both conditions must be true | `age > 20 and status eq 'ACTIVE'` |
| OR | `or` | `\|\|` | At least one condition must be true | `category eq 'A' or category eq 'B'` |

## Filter Examples

## Basic Filters

### Simple equality

```
persons.age == 30
```

### String comparison

```
persons.name eq 'John'
```

### Numeric comparison

```
persons.children.age > 5
```

### Null check

```
persons.spouse eq null
```

## Complex Filters

### Logical operators

```
persons.age > 30 and persons.gender eq 'M'
```

### Parentheses for grouping

```
(persons.age > 30 and persons.gender eq 'M') or persons.name eq 'Mary'
```

### Nested properties

```
persons.children.age > 10 and persons.children.gender eq 'F'
```

### Important Notes on Filters

- Parentheses: Use parentheses to control evaluation order
- String values: Must be enclosed in single quotes, e.g., `name eq 'John'`
- Null handling: Only `eq` and `ne` operators work meaningfully with null values
- Nested objects: Use dot notation to access nested properties

## Using Projections

Projections allow you to specify exactly which fields to include in your objects, effectively pruning all other fields. This is particularly useful for reducing memory usage and improving serialization performance.

## Projection Examples

- **Root level field:** `uuid`
- **Nested field:** `persons.name`
- **Multiple nested fields:** `persons.name`, `persons.age`, `persons.gender`
- **Deep nesting:** `persons.children.name`
- **All fields at a level:** `persons.*` (wildcard)

### Benefits of Using Projections

- Memory Efficiency: Include only the fields you need, reducing memory usage
- Performance: Improve serialization and deserialization performance with smaller objects
- Bandwidth Optimization: Reduce network traffic when transferring data
- Simplified Views: Create tailored views of complex data structures

## Combining Filters & Projections

DataSculptor allows you to combine the power of both query filtering and projection in a single operation for highly optimized and tailored data structures.

## Combined Example 1: Filter persons by age and project only names

- **Filter:** `persons.age > 30`
- **Projections:** `persons.name`, `persons.age`
- **Result:** Only persons over 30 years old with just their name and age fields

## Combined Example 2: Filter by nested properties and project specific fields

- **Filter:** `persons.children.gender eq 'F' and persons.children.age < 10`
- **Projections:** `persons.name`, `persons.children.name`, `persons.children.age`
- **Result:** Only persons with female children under 10, including only the specified fields

### Why Combine Filters and Projections?

By combining filters and projections, you get the maximum efficiency in a single operation - removing unnecessary elements from collections and then including only the fields you care about, resulting in highly optimized data structures tailored to your specific needs