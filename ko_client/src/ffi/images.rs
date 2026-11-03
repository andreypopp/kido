use std::ffi::{c_char, c_int};

use ko_server::api::Route;
use ko_server::http::Response;
use ko_server::protocol::{
    self, IMAGE_FORMAT_HEADER, IMAGE_FRAMES_HEADER, IMAGE_GAP_HEADER, IMAGE_GENERATION_HEADER,
    IMAGE_HEIGHT_HEADER, IMAGE_WIDTH_HEADER, ImageShm, PixelFormat,
};

use super::calls::{call, rejected};
use super::{Buffer, Client, Code, client, ko_buffer_free, text_of};
use crate::wire;

const NAME_CAPACITY: usize = 32;

#[repr(C)]
#[derive(Debug)]
pub struct Image {
    pub format: c_int,
    pub width: u32,
    pub height: u32,
    pub generation: u64,
    pub gap_ms: u32,
    pub frames: u32,
    pub length: u64,
    pub shm_name: [c_char; NAME_CAPACITY],
    pub body: Buffer,
}

fn format_number(format: PixelFormat) -> c_int {
    match format {
        PixelFormat::Rgb => 1,
        PixelFormat::Rgba => 2,
        PixelFormat::GrayAlpha => 3,
        PixelFormat::Gray => 4,
    }
}

fn number<T: std::str::FromStr>(response: &Response, name: &str) -> Option<T> {
    response.header(name)?.parse().ok()
}

fn described(response: &Response, accept_shm: bool) -> Option<ImageShm> {
    if accept_shm {
        let shm = protocol::decode::<ImageShm>(&response.body).ok()?;
        return (shm.name.len() < NAME_CAPACITY).then_some(shm);
    }
    Some(ImageShm {
        name: String::new(),
        length: u64::try_from(response.body.len()).ok()?,
        format: PixelFormat::from_header(response.header(IMAGE_FORMAT_HEADER)?)?,
        width: number(response, IMAGE_WIDTH_HEADER)?,
        height: number(response, IMAGE_HEIGHT_HEADER)?,
        generation: number(response, IMAGE_GENERATION_HEADER)?,
        gap_ms: number(response, IMAGE_GAP_HEADER)?,
        frames: number(response, IMAGE_FRAMES_HEADER)?,
    })
}

/// # Safety
///
/// `client` is a live handle. `pane` is a NUL-terminated string. `out` is
/// writable for one `ko_image`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ko_client_image(
    client_: *const Client,
    pane: *const c_char,
    image: u32,
    frame: u32,
    generation: u64,
    accept_shm: bool,
    out: *mut Image,
) -> Code {
    let (Some(client), Some(pane)) = (client(client_).filter(|_| !out.is_null()), text_of(pane))
    else {
        return Code::Argument;
    };
    let path = format!("/panes/{pane}/images/{image}/frames/{frame}?generation={generation}");
    let Ok(route) = Route::of_request("GET", &path) else {
        return Code::Argument;
    };
    let mut body = Buffer {
        data: std::ptr::null_mut(),
        len: 0,
        cap: 0,
    };
    let mut shm = None;
    let code = call(client, &mut body, |socket, client, cancel| {
        let response =
            wire::image(socket, client, &route, accept_shm, Some(cancel)).map_err(rejected)?;
        let Some(described) = described(&response, accept_shm) else {
            return Err((
                Code::Protocol,
                b"an image reply without its description".to_vec(),
            ));
        };
        shm = Some(described);
        Ok(if accept_shm {
            Vec::new()
        } else {
            response.body
        })
    });
    let Some(shm) = shm.filter(|_| code == Code::Ok) else {
        // SAFETY: out is non-null and writable by contract.
        unsafe {
            *out = Image {
                format: 0,
                width: 0,
                height: 0,
                generation: 0,
                gap_ms: 0,
                frames: 0,
                length: 0,
                shm_name: [0; NAME_CAPACITY],
                body,
            };
        }
        return code;
    };
    if accept_shm {
        // SAFETY: body is the empty buffer that call filled, freed here once.
        unsafe { ko_buffer_free(&mut body) };
    }
    let mut shm_name = [0; NAME_CAPACITY];
    for (slot, byte) in shm_name.iter_mut().zip(shm.name.bytes()) {
        *slot = byte as c_char;
    }
    // SAFETY: out is non-null and writable by contract.
    unsafe {
        *out = Image {
            format: format_number(shm.format),
            width: shm.width,
            height: shm.height,
            generation: shm.generation,
            gap_ms: shm.gap_ms,
            frames: shm.frames,
            length: shm.length,
            shm_name,
            body,
        };
    }
    code
}
