import { useEffect, useState } from "react";

/** A minute clock for the session ages, the exhausted band's "reset has
    passed" and the chip's limited state: read once on mount, then each minute. */
export function useNowMinute(): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 60_000);
    return () => clearInterval(id);
  }, []);
  return now;
}
