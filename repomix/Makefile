# Define include patterns (without quotes)
DEV_ENV_INCLUDE := .devcontainer,.vscode/**/*.json,.env,.gitignore,docker*,Makefile,process-test-file.sh,setup-android-debugging.ps1,repomix/Makefile
APP_INCLUDE := nissan_leaf_app/lib/*.dart,nissan_leaf_app/test/*.dart
DATA_INCLUDE := nissan_leaf_app/lib/data/*.dart,nissan_leaf_app/test/data/*.dart
UI_INCLUDE := nissan_leaf_app/lib/components/*.dart,nissan_leaf_app/test/components/*.dart,nissan_leaf_app/lib/pages/*.dart
OBD_INCLUDE := nissan_leaf_app/lib/obd/*.dart,nissan_leaf_app/test/obd/*.dart

# Helper function to expand include patterns to file list
# Usage: $(call get_source_files,include_pattern)

# Define a literal comma and space
comma := ,
space := $(empty) $(empty)

define get_source_files
$(shell find $(addprefix ../, $(subst $(comma),$(space),$(1))) -type f 2>/dev/null)
endef

# Default target
all: dev-env.rmx app-base.rmx data.rmx UI-components.rmx obd.rmx

debug:
	@echo "Pattern: $(APP_INCLUDE)"
	@echo "Expanded: $(call get_source_files,$(APP_INCLUDE))"


# Rules with direct dependency tracking
dev-env.rmx: $(call get_source_files,$(DEV_ENV_INCLUDE))
	cd .. && repomix -o repomix/$@ --include "$(DEV_ENV_INCLUDE)"

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
