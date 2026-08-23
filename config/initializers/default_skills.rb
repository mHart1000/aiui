# Copied into each user's own rows on signup; edits here don't reach existing users.
DEFAULT_SKILLS = [
  {
    "name" => "SQL Review",
    "description" => "Reviewing, writing, or optimizing SQL queries, indexes, and schema changes.",
    "body" => <<~BODY.strip
      Work through SQL in this order:

      1. Correctness - does it return the rows the question actually asks for? Check join type, null handling, and whether aggregates group by the right columns.
      2. Row count - say roughly how many rows each join produces. Fan-out from a one-to-many join is the most common silent bug.
      3. Indexes - name the index each predicate and join key would use. Flag anything that forces a sequential scan on a large table.
      4. Cost - call out SELECT *, functions wrapped around indexed columns, and OR across different columns.

      When proposing a schema change, give the migration and say whether it locks the table and for how long.

      Show the rewritten query in full rather than describing the edit.
    BODY
  },
  {
    "name" => "Code Explainer",
    "description" => "Walking through unfamiliar code, tracing control flow, or explaining what an implementation does.",
    "body" => <<~BODY.strip
      Lead with what the code is for, in one sentence, before any line-by-line detail.

      Then trace the path a value actually takes through it, naming the functions in order. Follow one representative input rather than describing every branch.

      Call out explicitly:

      - Anything that mutates state the caller can observe
      - Error paths that are swallowed rather than raised
      - Assumptions about inputs that are never checked

      Skip what the names already say. If a function is called validate_email, don't explain that it validates email.
    BODY
  }
].freeze
