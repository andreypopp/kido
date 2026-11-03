use serde_json::{Value, json};

use crate::harness::{DEADLINE, Message, Ws, poll, start, tagged};

fn lines_program(count: u32) -> String {
    format!(
        "stty raw -echo; i=0; while [ $i -lt {count} ]; do if [ $((i % 10)) -eq 0 ]; then printf 'row-%d NEEDLE\\r\\n' $i; else printf 'row-%d plain\\r\\n' $i; fi; i=$((i+1)); done; printf READY; exec cat"
    )
}

fn matches_until_done(search: &mut Ws) -> Vec<Value> {
    search.within(DEADLINE);
    let mut found = Vec::new();
    loop {
        let Message::Text(text) = search.read() else {
            panic!("a binary message on a search");
        };
        let (tag, payload) = tagged(&text).expect("a tagged event");
        match tag.as_str() {
            "matches" => found.extend(payload["matches"].as_array().unwrap().iter().cloned()),
            "done" => return found,
            other => panic!("unexpected {other}"),
        }
    }
}

#[test]
fn a_search_streams_its_matches_oldest_first_then_done_and_closes() {
    let s = start(&[]);
    let pane = s.pane(&lines_program(300));
    s.screen_has(&pane, "READY");
    let mut search = s.ws(&format!("/panes/{pane}/search?needle=needle"));
    let found = matches_until_done(&mut search);
    let rows: Vec<u64> = found.iter().map(|m| m["row"].as_u64().unwrap()).collect();
    assert_eq!(rows, (0..300).step_by(10).collect::<Vec<u64>>());
    assert_eq!(
        found[0],
        json!({"row": 0, "col": 6, "end_row": 0, "end_col": 11})
    );
    assert_eq!(
        found[29],
        json!({"row": 290, "col": 8, "end_row": 290, "end_col": 13})
    );
    search.closed("the server closes a finished search");
}

#[test]
fn closing_a_search_stops_it_and_the_pane_serves_the_next_one() {
    let s = start(&[]);
    let pane = s.pane(&lines_program(30000));
    s.screen_has(&pane, "READY");
    {
        let mut search = s.ws(&format!("/panes/{pane}/search?needle=needle"));
        search.within(DEADLINE);
        let Message::Text(first) = search.read() else {
            panic!("a binary message on a search");
        };
        assert_eq!(tagged(&first).unwrap().0, "matches");
    }
    let mut again = s.ws(&format!("/panes/{pane}/search?needle=row-29990"));
    let found = matches_until_done(&mut again);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0]["row"], 29990);
    poll("a screen of the pane after the cancelled search", || {
        s.screen(&pane).contains("READY")
    });
    assert!(!s.log().contains("error"), "{}", s.log());
}

#[test]
fn two_searches_of_one_pane_run_side_by_side_and_each_gets_its_own_done() {
    let s = start(&[]);
    let pane = s.pane(&lines_program(30000));
    s.screen_has(&pane, "READY");
    let mut many = s.ws(&format!("/panes/{pane}/search?needle=needle"));
    let mut one = s.ws(&format!("/panes/{pane}/search?needle=row-29990"));
    let single = matches_until_done(&mut one);
    assert_eq!(single.len(), 1);
    assert_eq!(single[0]["row"], 29990);
    let all = matches_until_done(&mut many);
    assert_eq!(all.len(), 3000);
}
