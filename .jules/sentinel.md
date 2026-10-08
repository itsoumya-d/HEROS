## 2025-05-25 - Prevent write-redirect attacks and FIFO blocking DoS
**Vulnerability:** Symlinks on critical data files allow write-redirect attacks, and FIFOs on read paths allow blocking DoS via `awk`.
**Learning:** Symlinks and irregular files must be explicitly rejected before operating on data files to ensure system availability and data integrity.
**Prevention:** Use fail-closed symlink checks (`[[ -L <file> ]]`) for data directories, and explicitly verify file regularity (`[[ ! -f <file> ]]`) before calling utilities like `awk`.
