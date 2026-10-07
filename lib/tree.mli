val order : id:('a -> 'id) -> parent:('a -> 'id option) -> 'a list -> 'a list
(** [order ~id ~parent items] returns [items] parent-first: every item follows the one whose id its
    parent names, recursively. Siblings keep the order they arrived in. [id] must be unique and
    non-empty; [parent] returns [""] for a root, and a parent naming no item in [items] is a root
    too.

    Every item comes out exactly once, tree or no tree: anything a walk from the roots missed (a
    cycle) is emitted afterwards as a root. *)
