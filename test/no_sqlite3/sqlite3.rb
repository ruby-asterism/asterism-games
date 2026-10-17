# frozen_string_literal: true

# rake test:gem puts this directory first on the load path: the gem alone
# has no sqlite3 (it is the Gemfile's, not the gem's), and the records take
# their JSON form (README "Game records").
raise LoadError, "cannot load such file -- sqlite3 (rake test:gem runs as without the sqlite3 gem)"
