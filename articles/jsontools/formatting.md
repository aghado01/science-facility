Overview
JSON Tools brings together a full suite of utilities for working with JSON in one place, from querying and anonymization to schema inference and encryption. It is a comprehensive guide featuring DataSculptor for query filtering with SQL-like expressions and projection, Generator for mock data creation from JSON Schema, Schema Detector for JSON Schema detection and inference, Formatter for beautification, Rewriter for field modification, Randomizer for data anonymization, and Converter for transformations between formats.

API usage details are included after the tool guides. See API Access for reference.

DataSculptor
DataSculptor is a powerful tool designed to sculpt your data by precisely query filtering with SQL-like expressions and projecting JSON data. It allows you to prune nested objects, filter collections based on field values, and create projections that include only specified fields, significantly reducing memory usage and improving performance in data-heavy applications.

The tool's name reflects its purpose - like a sculptor, it carefully removes the unnecessary parts to reveal the exact data shape you need.

Full guide: core concepts, supported filter operators, worked filtering examples, projection patterns, and combining both in one pass.

Read the DataSculptor guide →
JSON Formatter
The JSON Formatter is a simple but powerful tool that helps you validate, beautify, and work with JSON data effectively.

Full guide: validation with line/column error reporting, beautifying, the integrated viewer, remote JSON by URL, and large-file limits.

Read the JSON Formatter guide →
JSON Converter
The JSON Converter is a versatile independent tool that allows you to convert from JSON to other popular data formats including XML and YAML.

Full guide: target format selection, automatic pretty formatting, XML attribute handling, YAML indentation rules, and download options.

Read the JSON Converter guide →
JSON Rewriter
The JSON Rewriter is a powerful tool that allows you to modify specific JSON fields using path expressions. Perfect for updating values, changing nested properties, or transforming JSON data with surgical precision.

Full guide: path-based rewrites, nested object and array targeting, value format rules, and worked update examples.

Read the JSON Rewriter guide →
JSON Randomizer
The JSON Randomizer is a privacy-focused tool that anonymizes sensitive data by randomizing specific JSON fields while preserving data structure and types. Perfect for creating GDPR-compliant test data, masking PII, and generating generic mock datasets with placeholder values.

Full guide: dot-notation path targeting, per-type randomization rules, worked path examples, and GDPR/HIPAA use cases.

Read the JSON Randomizer guide →
JSON Encryption
Encrypt and decrypt individual JSON fields with Post-Quantum Cryptography, targeting values by dot-notation path while leaving the surrounding structure intact.

Full guide: key features, dot-notation path syntax for nested objects and arrays, worked encrypt/decrypt examples, and compliance use cases.

Read the JSON Encryption guide →
JSON Generator
The JSON Generator creates realistic mock JSON data from JSON Schema definitions. Perfect for API testing, development, and creating sample datasets with structured, schema-compliant data that follows your exact specifications.

Full guide: JSON Schema support, generated data patterns, supported constraints and formats, and mock-data use cases.

Read the JSON Generator guide →
Schema Detector & Inferrer
The Schema Detector & Inferrer automatically analyzes your JSON data and generates corresponding JSON Schema definitions. Perfect for API documentation, data validation, and understanding complex data structures by inferring schemas from real-world JSON examples.