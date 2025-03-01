#!/bin/bash
echo "!!Processing test output"

# Read JSON test log from stdin
#   - Remove print statements
#   - combine multi-line JSON objects into a single line
#   - filter only for errors
#   - extract test name, line, column, and file and make it easy to read
#   - print out in human friendly format
grep -v print | \
sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/ /g' -e 's/{\"test\"/\n{\"test\"/g' | \
grep '\"error\"' | \
while IFS= read -r line; do
#    echo "$line"
     
    # Extract test name, line, column, and file
    testName=$(echo "$line" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
    testLine=$(echo "$line" | grep -o '"line":[0-9]*' | cut -d':' -f2)
    testColumn=$(echo "$line" | grep -o '"column":[0-9]*' | cut -d':' -f2)
    testFile=$(echo "$line" | grep -o '"url":"[^"]*"' | cut -d'"' -f4 | sed 's|file:///app/||')
     
    # Extract testID and error message
    testID=$(echo "$line" | grep -o '"testID":[0-9]*' | head -1 | cut -d':' -f2)
    error=$(echo "$line" | grep -o '"error":"[^"]*"' | head -1 | cut -d'"' -f4)
    stackTrace=$(echo "$line" | grep -o '"stackTrace":"[^"]*"' | cut -d'"' -f4)
    stackTrace=$(echo "$stackTrace" | sed 's/\\n/\n/g')
    
      
    # Output machine-readable format for problemMatcher with test location
    echo "ERROR_MARKER: $testID | $error | $testName | $testFile | $testLine | $testColumn"
    
    # Output human-readable format
    echo "----------------------------------------"
    echo "Test '$testName' failed: $error"
    echo "Test location: $testFile line $testLine"
    echo "Stack trace:"
    echo -e "$stackTrace"
    echo "----------------------------------------"
done
echo "!!Done processing test output"