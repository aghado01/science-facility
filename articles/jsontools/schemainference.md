# Schema Detector & Inferrer

The Schema Detector & Inferrer automatically analyzes your JSON data and generates corresponding JSON Schema definitions. Perfect for API documentation, data validation, and understanding complex data structures by inferring schemas from real-world JSON examples.

### Key Features

- **Automatic Schema Generation:** Instantly detect and infer JSON Schema from any JSON data structure
- **Intelligent Type Detection:** Accurately identifies data types, formats, and patterns in your JSON
- **Complex Structure Support:** Handles nested objects, arrays, and mixed data types seamlessly
- **API Documentation Ready:** Generate schemas perfect for OpenAPI specifications and API documentation
- **Validation Ready:** Produces standards-compliant JSON Schema for data validation

## How to Use the Schema Detector

1. Navigate to the [Schema Detector & Inferrer tool](/schemadetector)
2. Paste your JSON data into the input area or load it from a file/URL
3. Click "Detect Schema" to automatically generate the JSON Schema
4. Review the inferred schema and copy it for use in your projects
5. Use the generated schema for validation, documentation, or code generation

## Example: From JSON to Schema

```
// Input JSON Data
{
  "users": [
    {
      "id": 1,
      "name": "John Doe",
      "email": "john@example.com",
      "age": 30,
      "active": true,
      "address": {
        "street": "123 Main St",
        "city": "New York",
        "zipCode": "10001"
      },
      "hobbies": ["reading", "swimming"]
    },
    {
      "id": 2,
      "name": "Jane Smith",
      "email": "jane@example.com",
      "age": 25,
      "active": false,
      "address": {
        "street": "456 Oak Ave",
        "city": "Los Angeles",
        "zipCode": "90210"
      },
      "hobbies": ["cooking", "hiking", "photography"]
    }
  ]
}

// Generated JSON Schema
{
  "type": "object",
  "properties": {
    "users": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "id": {
            "type": "integer"
          },
          "name": {
            "type": "string"
          },
          "email": {
            "type": "string",
            "format": "email"
          },
          "age": {
            "type": "integer"
          },
          "active": {
            "type": "boolean"
          },
          "address": {
            "type": "object",
            "properties": {
              "street": {
                "type": "string"
              },
              "city": {
                "type": "string"
              },
              "zipCode": {
                "type": "string"
              }
            },
            "required": ["street", "city", "zipCode"]
          },
          "hobbies": {
            "type": "array",
            "items": {
              "type": "string"
            }
          }
        },
        "required": ["id", "name", "email", "age", "active", "address", "hobbies"]
      }
    }
  },
  "required": ["users"]
}
```

## Schema Detection Features

### Data Type Detection

- • `string` - Text values
- • `number` - Numeric values
- • `integer` - Whole numbers
- • `boolean` - True/false values
- • `array` - Lists and collections
- • `object` - Nested structures

### Format Recognition

- • `email` - Email addresses
- • `date-time` - ISO timestamps
- • `date` - Date values
- • `uri` - URLs and URIs
- • `uuid` - UUID patterns
- • `ipv4` - IP addresses

### Structure Analysis

- • `required` - Required fields detection
- • `properties` - Object property mapping
- • `items` - Array item schemas
- • `additionalProperties` - Flexible objects
- • Nested object hierarchies
- • Mixed array types

### Advanced Features

- • Pattern recognition for strings
- • Enum value detection
- • Constraint inference
- • Multiple example handling
- • Optional field detection
- • Schema optimization

## Use Cases

- API Documentation: Generate schemas for OpenAPI specifications and API documentation from real response data
- Data Validation: Create validation schemas for input data, forms, and API endpoints
- Code Generation: Generate TypeScript interfaces, database schemas, or model classes from JSON data
- Data Analysis: Understand the structure and types of complex datasets and JSON files
- Quality Assurance: Infer schemas from test data to ensure consistent data structures across environments

## Pro Tips for Schema Detection

- Use Representative Data: Provide JSON samples that include all possible fields and data variations
- Review Generated Schema: Always review the generated schema for accuracy and adjust constraints as needed
- Combine with Generator: Use the detected schema with the JSON Generator to create consistent test data
- Handle Edge Cases: Include null values, empty arrays, and optional fields in your sample data
- Validate Results: Test the generated schema against your actual data to ensure compatibility