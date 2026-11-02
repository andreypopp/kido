use ko_pane_wire::frame::Limits;
use ko_server::ids::{ClientId, Instance};
use ko_server::protocol::{self, ClientEvent, Row};

use crate::wire::{Link, Next, text};

#[derive(Debug)]
pub struct Model {
    pub client: ClientId,
    pub instance: Instance,
    pub limits: Limits,
    pub panes: Vec<Row>,
}

impl Model {
    pub fn welcome(link: &mut Link) -> Result<Model, String> {
        let mut next = || match link.receive().map_err(text)? {
            Next::Text(event) => protocol::decode::<ClientEvent>(event.as_bytes()).map_err(text),
            _ => Err("client event missing".to_owned()),
        };
        let ClientEvent::Welcome(welcome) = next()? else {
            return Err("welcome missing".to_owned());
        };
        let ClientEvent::Topology { panes } = next()? else {
            return Err("topology missing".to_owned());
        };
        Ok(Model {
            client: welcome.client,
            instance: welcome.instance,
            limits: welcome.limits.terminal.limits(),
            panes,
        })
    }

    pub fn apply(&mut self, event: ClientEvent) {
        match event {
            ClientEvent::Topology { panes } => self.panes = panes,
            ClientEvent::Title(title) => {
                for row in self.panes.iter_mut().filter(|row| row.id == title.pane) {
                    row.title.clone_from(&title.title);
                }
            }
            ClientEvent::Dead(dead) => {
                for row in self.panes.iter_mut().filter(|row| row.id == dead.pane) {
                    row.dead = Some(dead.dead.clone());
                }
            }
            ClientEvent::Welcome(_) | ClientEvent::Pwd(_) => {}
        }
    }
}
