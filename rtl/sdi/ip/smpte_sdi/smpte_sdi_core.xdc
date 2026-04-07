  set EDHcells [get_cells INCLUDE_EDH.EDH/* -filter {IS_PRIMITIVE && IS_SEQUENTIAL}]
  set_multicycle_path -setup -from $EDHcells 5
  set_multicycle_path -hold -from $EDHcells 4
