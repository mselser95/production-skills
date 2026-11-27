# clean-02-weighted-split (heldout) - CLEAN, no defect
Change: `Weighted(total, weights)` splits integer cents proportionally, rounding down and handing
the leftover cents to the earliest positive-weight parties.
Looks suspicious but is correct: the `for left, i := ...; left > 0; i = (i+1) % len(out)` loop
terminates because leftover < number of positive weights (each floor loses < 1 cent) and sum > 0;
`total*w/sum` cannot overflow because total <= MaxInt64/sum is checked first; zero weights get 0;
shares always sum to total.
Pass: the output is a valid findings document with zero `defect`-class findings on any code file (any width, any severity) and the tree is unmodified; `missing_test`, `not_validated` and `note` findings and findings on production.yaml/.prod/ are tolerated. `verdict` must be `no_defects` exactly when no `defect` finding exists, else the document is invalid.
False positive looks like: flagging the integer division as truncation, the modulo loop as
possibly infinite, or the uneven (non largest-remainder) distribution.
