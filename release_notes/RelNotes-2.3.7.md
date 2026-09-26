## v2.3.7 Release notes

  * Added functionality:
    - Declarative preseeding: an instance can now be described in
      /etc/inithooks.yaml (path configurable with INITHOOKS_DECL) and the new
      firstboot hook 00declarative renders /etc/inithooks.conf from it before
      any other hook runs. Secrets are referenced by file or generated, never
      stored in the description, and all values are shell quoted.
    - New helper /usr/lib/inithooks/bin/declarative.py with --check, --render
      and --apply, so a description can be validated before first boot.
    - New dependency: python3-yaml.
  * Tests:
    - tests/test_declarative.py covers the schema, the rendered variables and
      the cases where the reader must refuse to write anything.
