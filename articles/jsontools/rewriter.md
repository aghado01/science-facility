# JSON Rewriter

The JSON Rewriter is a powerful tool that allows you to modify specific JSON fields using path expressions. Perfect for updating values, changing nested properties, or transforming JSON data with surgical precision.

## Key Features

- Path-Based Modification: Target specific fields using intuitive dot notation paths
- Precise Updates: Modify only the fields you specify while preserving the rest of your JSON structure
- Multiple Rewrites: Apply multiple field modifications in a single operation
- Deep Nesting Support: Navigate and modify fields at any depth in complex JSON structures
- Array Index Support: Modify specific elements in arrays using numeric indices
- Type Preservation: Maintains proper JSON data types (strings, numbers, booleans, null) in the output

## How to Use the JSON Rewriter

1. Select the "JSON Rewriter" tab in the main playground
2. Enter or paste your JSON data into the input field, or upload a JSON file
3. Add path rewriters by specifying the field path and new content:
   - Enter the path to the field you want to modify (e.g., `persons.0.name`)
   - Enter the new content for that field (e.g., `"Alice Smith"`)
   - Click "Add" to add the rewriter rule
4. Repeat step 3 to add multiple rewriter rules
5. Click "Rewrite JSON" to apply all modifications
6. View the modified JSON in the output panel
7. Download the rewritten JSON in your preferred format (JSON, XML, or YAML)

## Path Syntax Examples

### Basic Field Access

To modify a top-level field:

`Path: "name"`

Changes: {"name": "John"} becomes {"name": "Alice"}

### Nested Object Access

To modify a nested field:

`Path: "person.address.city"`

Modifies city in nested address object

### Array Element Access

To modify a specific array element:

`Path: "users.0.name"`

Modifies name of first user in users array

### Deep Nested Array Access

To modify fields deep in nested arrays:

`Path: "departments.0.employees.1.contact.email"`

Modifies email of second employee in first department

## Content Format Examples

### String Values

Use double quotes for string values:

`"Alice Smith"` `"New York City"`

### Numeric Values

Enter numbers without quotes:

`42` `3.14159` `-100`

### Boolean Values

Use lowercase true/false:

`true` `false`

### Null Values

Use lowercase null:

`null`

### Complex Objects

Replace entire objects or arrays:

`{"name": "Alice", "age": 30}` `[1, 2, 3, 4, 5]`

### Pro Tips for JSON Rewriter

- Batch Operations: Add multiple rewriter rules before processing to apply all changes in one operation
- Path Validation: Invalid paths are handled gracefully - the rewriter won't crash if a path doesn't exist
- Format Conversion: After rewriting, convert your JSON to XML or YAML using the download options
- Data Masking: Perfect for anonymizing sensitive data by replacing names, emails, or other PII with placeholder values
- Testing & Development: Quickly modify API responses or test data without manual JSON editing
- Integration: Use in combination with DataSculptor - first filter your data, then rewrite specific fields