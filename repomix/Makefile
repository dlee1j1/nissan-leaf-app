# Define include patterns (without quotes)
APP_INCLUDE := nissan_leaf_app/lib/*.dart,.devcontainer,.vscode/**/*.json,.env,.gitignore,docker*,Makefile,process-test-file.sh,setup-android-debugging.ps1
DATA_INCLUDE := nissan_leaf_app/lib/data/*.dart,nissan_leaf_app/test/data/*.dart
UI_INCLUDE := nissan_leaf_app/lib/components/*.dart,nissan_leaf_app/test/components/*.dart,nissan_leaf_app/lib/pages/*.dart
OBD_INCLUDE := nissan_leaf_app/lib/obd/*.dart,nissan_leaf_app/test/obd/*.dart

# Helper function to expand include patterns to file list
# Usage: $(call get_source_files,include_pattern)
define get_source_files
$(patsubst %,../%,$(shell cd .. && find $(subst *,*,$(subst ,,$(1))) -type f 2>/dev/null))
endef

# Default target
all: app-base.rmx data.rmx UI-components.rmx obd.rmx

# Rules with direct dependency tracking
app-base.rmx: $(call get_source_files,$(APP_INCLUDE))
	cd .. && repomix -o repomix/$@ --include "$(APP_INCLUDE)"

data.rmx: $(call get_source_files,$(DATA_INCLUDE))
	cd .. && repomix -o repomix/$@ --include "$(DATA_INCLUDE)"

UI-components.rmx: $(call get_source_files,$(UI_INCLUDE))
	cd .. && repomix -o repomix/$@ --include "$(UI_INCLUDE)"

obd.rmx: $(call get_source_files,$(OBD_INCLUDE))
	cd .. && repomix -o repomix/$@ --include "$(OBD_INCLUDE)"

# Clean target 
clean:
	rm -f *.rmx

# Force regeneration of all rmx files
force:
	rm -f *.rmx
	$(MAKE) all
