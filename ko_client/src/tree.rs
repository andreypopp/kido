use std::collections::BTreeMap;

pub(crate) fn order<T, K: Ord>(
    items: Vec<T>,
    id: impl Fn(&T) -> K,
    parent: impl Fn(&T) -> Option<K>,
) -> Vec<(T, usize)> {
    let index: BTreeMap<K, usize> = items
        .iter()
        .enumerate()
        .map(|(at, item)| (id(item), at))
        .collect();
    let mut children: Vec<Vec<usize>> = items.iter().map(|_| Vec::new()).collect();
    let mut roots = Vec::new();
    for (at, item) in items.iter().enumerate() {
        match parent(item)
            .and_then(|parent| index.get(&parent).copied())
            .filter(|found| *found != at)
        {
            Some(found) => children[found].push(at),
            None => roots.push(at),
        }
    }
    let mut seen = vec![false; items.len()];
    let mut walk: Vec<(usize, usize)> = Vec::with_capacity(items.len());
    for start in roots.into_iter().chain(0..items.len()) {
        let mut stack = vec![(start, 0)];
        while let Some((at, depth)) = stack.pop() {
            if std::mem::replace(&mut seen[at], true) {
                continue;
            }
            walk.push((at, depth));
            stack.extend(children[at].iter().rev().map(|child| (*child, depth + 1)));
        }
    }
    let mut slots: Vec<Option<T>> = items.into_iter().map(Some).collect();
    walk.into_iter()
        .filter_map(|(at, depth)| Some((slots[at].take()?, depth)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shown(items: &[(&str, &str)]) -> Vec<String> {
        order(
            items.to_vec(),
            |(id, _)| *id,
            |(_, parent)| (!parent.is_empty()).then_some(*parent),
        )
        .into_iter()
        .map(|((id, _), depth)| format!("{depth}{id}"))
        .collect()
    }

    #[test]
    fn every_item_comes_out_once_whatever_the_parent_edges_say() {
        let cases: [(&str, &[(&str, &str)]); 10] = [
            ("empty", &[]),
            ("one root", &[("a", "")]),
            ("self-parent", &[("a", "a")]),
            ("two-cycle", &[("a", "b"), ("b", "a")]),
            ("three-cycle", &[("a", "c"), ("b", "a"), ("c", "b")]),
            ("cycle with a child", &[("a", "b"), ("b", "a"), ("c", "a")]),
            ("absent parent", &[("a", "ghost"), ("b", "")]),
            ("duplicate ids", &[("a", ""), ("a", ""), ("b", "a")]),
            (
                "chain four deep",
                &[("d", "c"), ("c", "b"), ("b", "a"), ("a", "")],
            ),
            (
                "two roots, one deep",
                &[("a", ""), ("b", "a"), ("c", ""), ("d", "b")],
            ),
        ];
        for (name, items) in cases {
            assert_eq!(shown(items).len(), items.len(), "{name}");
        }
    }

    #[test]
    fn a_child_follows_its_parent_at_one_more_depth_in_arrival_order() {
        assert_eq!(
            shown(&[
                ("shell", ""),
                ("kid2", "top"),
                ("top", ""),
                ("kid1", "top"),
                ("grandkid", "kid2")
            ]),
            ["0shell", "0top", "1kid2", "2grandkid", "1kid1"]
        );
        assert_eq!(
            shown(&[("a", "b"), ("b", "a"), ("c", "a")]),
            ["0a", "1b", "1c"]
        );
        assert_eq!(shown(&[("a", "ghost"), ("b", "")]), ["0a", "0b"]);
    }

    #[test]
    fn the_order_is_deterministic() {
        let owned: Vec<(String, String)> = (0..40)
            .map(|at| {
                (
                    at.to_string(),
                    if at == 0 {
                        String::new()
                    } else {
                        (at % 7).to_string()
                    },
                )
            })
            .collect();
        let items: Vec<(&str, &str)> = owned
            .iter()
            .map(|(a, b)| (a.as_str(), b.as_str()))
            .collect();
        let first = shown(&items);
        assert!((0..20).all(|_| shown(&items) == first));
    }
}
