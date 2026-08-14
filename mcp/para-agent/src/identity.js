/**
 * Return whether a JavaScript string is a well-formed Unicode scalar sequence.
 * This avoids UTF-8 replacement collisions when logical identities are hashed
 * or routed to durable storage.
 */
export function isWellFormedUnicode(value) {
  if (typeof value !== "string") return false;
  for (let index = 0; index < value.length; index++) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
      index++;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}
