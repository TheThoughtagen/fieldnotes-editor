function normalize(path: string): string {
  const absolute = path.startsWith("/");
  const parts: string[] = [];
  for (const part of path.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") { if (parts.length > 0 && parts.at(-1) !== "..") parts.pop(); else if (!absolute) parts.push(part); }
    else parts.push(part);
  }
  return `${absolute ? "/" : ""}${parts.join("/")}` || (absolute ? "/" : ".");
}

function dirname(path: string): string {
  const normalized = normalize(path);
  const slash = normalized.lastIndexOf("/");
  return slash < 0 ? "." : slash === 0 ? "/" : normalized.slice(0, slash);
}

function join(...parts: string[]): string { return normalize(parts.filter(Boolean).join("/")); }

export const posix = Object.freeze({ normalize, dirname, join });
