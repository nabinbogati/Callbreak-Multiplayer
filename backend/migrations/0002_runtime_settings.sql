-- Runtime-tunable defaults, editable from the admin dashboard without a
-- restart. One row per setting, values as operator-typed strings (durations
-- like "5s", integers). The row set is always a full snapshot of the settings
-- package's Values, so a save replaces wholesale rather than patching.
CREATE TABLE runtime_settings (
    key        text PRIMARY KEY,
    value      text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);
