# JSON Encryption

The JSON Encryption tool provides secure field-level encryption and decryption for JSON data using **Post-Quantum Cryptography (PQC)** - advanced algorithms designed to resist attacks from both classical and quantum computers. Perfect for protecting sensitive information with future-proof encryption that ensures your data remains secure even against emerging quantum computing threats.

## Key Features

- Post-Quantum Cryptography (PQC): Future-proof encryption using quantum-resistant algorithms that protect against both classical and quantum computing attacks
- Field-Level Encryption: Encrypt specific JSON fields using dot notation paths (e.g., `user.email`, `user.address.zipCode`)
- Bidirectional Operation: Both encrypt plaintext fields and decrypt encrypted data with the same tool
- Structure Preservation: Maintains JSON structure while encrypting only the specified field values
- Nested Path Support: Handle deeply nested objects and arrays with precise path targeting

## How to Use

1. Navigate to the "Encryption" tool from the main menu
2. Enter or paste your JSON data into the input field, or upload a JSON file
3. Add field paths to encrypt/decrypt by specifying the JSON paths:
   - Enter the path to the field (e.g., `user.name`, `user.address.street`)
   - Click "Add Field" to include it in the selection
   - Repeat to add multiple fields
4. Choose your operation:
   - **Encrypt:** Convert plaintext field values to encrypted format
   - **Decrypt:** Convert encrypted field values back to plaintext
5. Click "Process JSON" to apply the encryption/decryption
6. View the processed JSON in the result area
7. Download the result in your preferred format (JSON, XML, or YAML)

## Path Syntax Examples

### Basic Field Access

**Path:** user.name

Targets the "name" field inside the "user" object

### Nested Objects

**Path:** user.address.street

Targets the "street" field inside "address" inside "user"

### Array Elements

**Path:** users.0.email

Targets the "email" field of the first user in the "users" array

### Complex Nested Paths

**Path:** company.employees.0.personalInfo.ssn

Targets deeply nested sensitive data

## Practical Examples

### Example: Encrypting User Personal Data

Original JSON:

```
{
  "user": {
    "id": 12345,
    "name": "John Doe",
    "email": "john.doe@example.com",
    "address": {
      "street": "123 Main St",
      "city": "Anytown",
      "zipCode": "12345"
    },
    "active": true
  }
}
```

After Encrypting name, email, and zipCode:

```
{
  "user": {
    "id": 12345,
    "name": "enc_AGF8a9sk2P...",
    "email": "enc_KL9j2mP4x...",
    "address": {
      "street": "123 Main St",
      "city": "Anytown",
      "zipCode": "enc_7nM3qR8z..."
    },
    "active": true
  }
}
```

**Fields encrypted:** `user.name`, `user.email`, `user.address.zipCode`