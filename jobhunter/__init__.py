"""job-hunter: self-hosted job-search assistant (finds, scores, drafts – never auto-applies)."""
__version__ = "1.1.0"  # gleiche Version wie die Mac-App (job-hunter-mac/VERSION); bei jedem Release beide erhöhen


def same_release(a: str | None, b: str | None) -> bool:
    """Server and Mac app belong together when major.minor match (patch may differ)."""
    def mm(v: str | None) -> tuple:
        return tuple((v or "").strip().split(".")[:2])
    return bool(a and b) and mm(a) == mm(b)
