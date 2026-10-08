## 2024-06-18 - Missing symlink and regular file checks in forge bridge
**Vulnerability:** Write-redirect attacks and FIFO blocking DoS
**Learning:** Ensure regular file verification before awk and fail-closed symlink checks for critical files
**Prevention:** Add fail-closed symlink checks and file validation before file interaction