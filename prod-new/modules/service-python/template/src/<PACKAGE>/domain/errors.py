"""Explicit domain error types. Callers match on the class, never on a message."""


class DomainError(Exception):
    """Base class of every error the domain raises on purpose."""


class InvalidAmount(DomainError):  # noqa: N818 - the domain names errors for the condition, not "Error"
    """The text or value is not a valid non-negative amount."""


class InvalidEvent(DomainError):  # noqa: N818
    """An event is malformed (for example an empty or oversized id)."""


class InsufficientFunds(DomainError):  # noqa: N818
    """A withdrawal exceeds the balance; the balance is never allowed to go negative."""


class AmountLimitExceeded(InvalidAmount):
    """An amount or a balance would exceed the one upper bound (``money.MAX_MINOR``)."""


class ZeroAmount(InvalidAmount):
    """A deposit or withdrawal of zero minor units: it changes nothing, so it is no event."""
