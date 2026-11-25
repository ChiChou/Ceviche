# Features

What the app ships today, by area. Names match the menus.

## Library

- **Catalogs.** A catalog is a `.cevichecatalog` package holding the database, previews and, if you choose, copies of
  the originals. Edits are nondestructive and never touch the original file. Open, close and back up catalogs from
  the File menu; a backup can include the originals. A catalog last opened by a newer version, or whose database
  fails to open or upgrade, can still be opened read-only to browse and export from, with nothing in it changed.
- **Welcome screen.** Shown when no catalog is open: one column with import, new and open catalog actions, Browse Folders, recent catalogs and Models, beside a credited photo or looping clip in wide windows, with arrows to step through the others. Return opens the most
  recent one.
- **iCloud catalogs.** Available in builds configured for iCloud. Ratings, metadata, edits, albums, trash and snapshots sync between Macs. Originals are not
  uploaded; each Mac reads them from its own disks. Work continues offline and syncs later.
- **Folders tab.** Browse folders on disk without importing. Edits on browsed photos are saved to XMP sidecars beside
  them (`IMG.ceviche.xmp` when another app wrote `IMG.xmp`). RAW files opened from the Finder show here. The last folder
  shown opens again at launch and on coming back from the Library.
- **Import.** From folders, cards, cameras and the Photos library. Originals are referenced in place by default, or
  copied into the catalog by month. Cards and drives are remembered by volume, so photos on an unplugged drive show as
  offline rather than missing. A photo can be opened as soon as it lands: its thumbnail is the camera's embedded
  preview, and photos whose XMP sidecar changes their look are rendered right after, or as they scroll into view when
  the originals are on a network share or another drive. Tagging and faces follow in the background without holding
  up the import. The grid switches to the new batch only from the whole catalog or a finished import's batch; a
  search, filter, album or folder being shown stays put. Files that fail to import are listed with their full path and why; the list can be copied, and
  reopened from the import's entry in the activity center until the app quits.
- **Organizing.** Ratings, pick and reject flags, color labels, albums and groups. Moving a folded group to the Trash moves all its photos; a photo moved to the Trash leaves its group, and Undo puts it back in. Recently Added lists the last
  imports by day. Search covers text, tags, places and EXIF; the empty search field lists the most used keywords
  and automatic tags, or all of them, to add to the search with a click. The map shows geotagged photos. **Set Location…** in the Info panel's
  Place section places one photo or a selection on a map, by search, coordinates or a click; a location set this way
  or by an MCP client is marked Set in Ceviche, framed with a dashed line on the map, and found with `location:set`
  (`location:file` and `location:none` find the others). **Show Nearby Photos** opens the Map zoomed to a photo's
  surroundings, so it shows the photos taken close by; **Show Photos from Same Day** lists the library's photos from
  the day a photo was taken. The Faces filter beside
  the search field shows photos with faces, without, or Group Photos (three faces or more), as background tagging
  finds them; photos it hasn't reached yet match none of the three.
- **Views.** The switch in the bottom bar and the View menu are the same everywhere: Wall ⌘1, Grid ⌘2, Compare ⌘3 and
  Detail ⌘4; G toggles Wall and Grid. Map and People add their overview before them (⌘↑ goes back up to it), and their
  photos, a pin's or a person's, show in the wall and the grid like any collection's.
- **Map.** Shows geotagged photos as pins. Choose a pin to list its photos below the map, then Show Photos (Return)
  to open them in the wall or the grid under a bar with the place's name.
- **People.** The sidebar item after Map. Faces are grouped by who they are: a card
  per person, named people first, plus Ungrouped and All Faces. Double-click a person to see their faces or, with
  Photos in the bar above, their photos, and name them there; drag one card onto another or Merge to join them, and
  Move To or Remove from Person to correct a face, which grouping then leaves where you put it. Click a face to select
  its photo, double-click or Return to
  open it, and Space to see the face at actual pixels from the original.
- **Date and import menus.** Right-click a period in Capture Date, or a date or session under Recently Added to Select Photos, Export…, Add to Album, or Move to Trash…. Actions include every photo in that group; Move to Trash… asks for confirmation with the photo count.
- **Duplicate.** Makes a second original beside each selected photo, as an APFS clone, with its own edits.
- **Trash and housekeeping.** The catalog's Trash keeps a photo's edits and history until emptied with Empty Trash… in its context menu. Settings › General shows the cache of decoded RAWs, which keeps recent photos opening fast, with Clear Cache. Move Missing Photos
  to Trash clears entries whose file is gone, ignoring drives that are just unplugged. Locate Original and Replace
  Original relink a moved or swapped file.
- **History and snapshots.** Every saved step is listed with a thumbnail; going back adds a new step, so nothing is
  lost. Snapshots are named versions. Restore returns to a step or a snapshot.
- **Activity.** Imports, exports, merges and other background work show as one progress ring in the title bar; clicking it
  lists each job with its progress, time left and a stop button, then what finished recently. The Dock icon shows the same
  progress as a bar.
- **Views.** Grid, wall and compare. Sorted by capture date with Group by Date on (in the sort menu), the grid, the
  wall and Faces start each day on a new row under its date, pinned at the top while you scroll. The calendar button
  beside the sort menu lists the years and months to go to; a month without photos goes to the nearest one. With two displays, a secondary window shows the selected photo full screen.

## Culling

All culling tools set only Pick and Reject flags, or groups; none deletes or edits. They work on the selection, or on
the photos shown, up to 10,000 at a time, and measure RAWs from the camera's preview rather than decoding the whole file.
Closing a tool stops measuring the photos it asked for. Their large preview shows the original undeveloped: pinch,
⌘-scroll or click to zoom, drag or scroll to move, and once zoomed in it reads the whole file so 100% is actual pixels.

- **Find Flawed Photos.** Measures every photo for blur, missed focus, exposure and closed eyes, then lists the
  suspects by problem. A dark photo shot at night, at dusk or with exposure compensation of −1 EV or less is not called
  underexposed. Closed eyes are judged on the eyelids too, so a laughing squint isn't
  called a blink. The sensitivity setting re-judges without measuring again.
- **Pick from Bursts.** Finds runs of similar frames from one camera and picks the best of each by sharpness, eyes and
  aesthetics. Copies and frames of the same instant with nearly the same picture are marked Duplicate within their
  burst. The gap between frames and how similar they must be are adjustable. A burst can instead be set to Group
  (folded under a key photo, flags left alone) or Skip, one by one or with Group All and Skip All; Apply does all of it
  in one step. Timelapse and night-sky sequences shot at a steady interval show as Timelapse, with the interval and any
  missing frames, and are grouped rather than picked from. Merge with Above joins a group to the one before it; Split
  undoes it.
- **Check Faces.** Lays out every series of group shots one after another, each with a column per person and a row per
  frame, faces shown at once from the camera preview and cut from the original where they are small, closed eyes marked, to find the frame where everyone is at their best; Photos shows each photo as a card
  of its faces instead. Photos with people are looked at again more closely, which finds the small faces of a group the
  culling measure misses. The chosen photo stays open beside them with its faces in a strip below; a face or its number
  zooms to it at actual pixels. Pick and Reject are set as you go and applied together.
- **RAW + JPEG pairs.** Pairs shot together are grouped under the RAW. Tidy RAW + JPEG Pairs decides which file of each shot
  stays: both, the RAW, the JPEG, or the RAW with the JPEG archived.
- **Move Rejected Photos to Trash.** Gathers the rejects in scope and moves them to the catalog's Trash.
- **Show Similar Photos.** Lists the photos that look most like the chosen one, nearest first, from Apple's image
  feature prints taken during background analysis.
- **Duplicates.** The sidebar's Duplicates lists copies and near-identical shots taken in the same second across the
  whole library, side by side, from the same feature prints; a camera's RAW and JPEG of one shot are left out.

## Develop

- **Light & Color.** Exposure, contrast, highlights, shadows, whites, blacks, white balance, vibrance, Color Mixer,
  point color, color grading wheels, tone and parametric curves, B&W mixer and calibration; in black and white the B&W
  mixer moves up under Color. HDR editing: the HDR section sets the HDR limit and SDR exposure, and Preview SDR shows
  the SDR rendition without changing the edit.
- **Scopes.** Under the histogram, Waveform, Parade and Vectorscope show one scope at a time; clicking the one that
  is on turns it off, as does View › Scopes (⌥⌘K), which also turns the last one back on. The Waveform plots each column
  of the photo's red, green and blue levels from black at the bottom to white at the top, with stops above SDR white in
  the upper half for HDR; the Parade shows the same levels in three side-by-side panes, one per channel; the
  Vectorscope plots hue around the circle and saturation outward, inside a rim of hues with a dot on red, yellow, green,
  cyan, blue and magenta, sRGB's outline and the skin tone line. The badge in the scope's corner switches the waveform
  to luma (Y) or zooms the vectorscope in 2×, and hovering reads out the level, or the hue and saturation. The scopes
  grow with the Develop panel, which widens by dragging its left edge.
- **Zones.** The Zones toggle beside the scopes, or View › Zones (⌥⌘Z), shows the photo in Light & Color as the eleven
  zones of the Zone System, 0 to X in equal steps of L* with zone V at middle grey, for judging tones in black and
  white. The strip above the photo shows each zone's share of the photo and rings the zone under the pointer; hovering a zone
  picks it out on the photo in yellow, and clicking keeps it picked out while the sliders move.
- **Detail.** Sharpening and RAW noise reduction from Apple's decoder come first, then Presence (texture, clarity and
  dehaze) and Optics, with the RAW decoder's lens correction and Wide-Angle Faces. Film grain and vignette follow,
  folded until opened.
- **Defringe.** Reduces purple and green fringes along edges. The eyedropper sets the hue range from a fringe in the photo, and both the amount and hue range are adjustable.
- **Looks.** Presets, camera profiles, DCP looks, `.cube` and Hald LUTs, and XMP develop presets from other raw editors. The Looks panel has two
  tabs: Built-in lists the included presets by category, one open at a time, and Mine the presets and LUTs you saved
  or imported, in their folders. Whatever is on the photo (preset, camera profile, imported look or LUT) shows above
  the library with its Amount and switch.
- **Darkroom.** Prints the photo through a film stock and paper with a spectral model: exposure, push and pull, grain,
  halation, paper grade, dodge and burn. Film rendering switches it on and off, keeping its settings.
- **Crop.** Crop with aspect presets, rotate and flip. Upright straightens automatically, by level or vertical lines,
  or from guides you draw; manual transform covers the rest. Straighten's Eyes levels the line through the eyes of
  the largest face, for a portrait taken with the camera tilted. **Volume** undoes the stretch a wide-angle lens gives
  things near the edges, across the whole photo: Horizontal and Vertical keep straight lines in that direction,
  Spherical fixes the corners too; it uses the EXIF focal length, which can be changed. Return (Done) keeps the
  changes; Esc undoes them and closes the tool.
- **Retouch.** Remove, Heal and Clone brushes, with AI fill that rebuilds the brushed area. Hand (or Esc) puts the
  brush down to zoom and pan; Select clicks or boxes stroke pins to change or delete several at once. Object removes
  what a click lands on: a sign or a bin outlined by Vision, or a wire followed along its length until something
  stops it, outlined under the pointer before the click, as ordinary strokes to change or delete. Shift-click
  collects several to remove together and Option-click drops one; a plain click removes them, puts the
  tool down, and the area shimmers until its AI fill lands. Distraction
  Removal finds dust as spots to review on the photo, and Find People covers everyone but the subject in strokes
  listed under People, whose pins are deleted to keep someone.
- **Portrait.** Blemishes, Light, Features and Reshape for the faces it finds. With
  several faces, a row above the cards picks whom they work on: Main subjects (the larger faces) or one
  person, also picked with the tag above a face on the photo; a face pointed at in the row is framed on the photo.
  Every person's corrections, spots, Even tone and reshape are their own: on one person the controls and resets touch
  only them, on Main subjects all of them, and a value that differs between them shows as a dash. White balance and
  Red eye are the whole photo's. Find blemishes, in the card or under each selected face framed on the photo in Remove Spots (with Clear beside it
  once the face has spots), places spots that are moved, resized or deleted on the photo; a click
  adds one and a drag boxes several. They are ordinary retouch strokes kept as Face spots, which Retouch lists as a
  group of their own. Each section switches off with its checkmark, as in Light & Color, keeping its settings. A bar
  over the photo picks what a click there does: Photo, Remove Spots, Touch Up (a face's teeth, lips, eyes or brows,
  tinted under the pointer, open their Features correction for that person), Reshape (the face's handles) or
  Reframe. Reshape works on one person: on Main subjects it picks the largest, and a click
  on another face picks them.
- **Reshape.** Portrait › Reshape is a face-aware liquify: eye size and distance, nose width, smile, mouth width, forehead, face width,
  jawline and chin height, set with sliders or by dragging handles on the face's features (Reshape in the bar), placed from
  the face's landmarks. A double-click on a slider or a handle puts it back. It follows a tilted or turned head:
  in profile the hidden eye and the near cheek are left alone and the jaw is pulled in along the jawline.
- **Reduce shine.** Measures the shine on each face from the RAW's own light, so exposure and highlight edits don't
  count as oil, and adds an editable local mask; refine it in Masks.
- **Even tone.** In Portrait › Light, evens blotches and redness on each face with a learned blend layer that keeps
  pores and hair; each person has their own Amount.
- **Features.** Portrait › Features makes small corrections on the selected people's teeth, eyes, lips and eyebrows,
  each measured from the feature's own pixels: teeth lose part of a yellow cast, eye whites their redness, pale lips
  gain some vibrance and faint brows darken. A feature with nothing to correct is left alone and Auto says so. Each is
  a People mask, editable in Masks, with a slider from none to twice what Auto measured. Red eye finds red pupils and
  neutralizes them with Fix; Remove takes that out.
- **Reframe.** Reframe in Portrait's bar over the photo draws crops around the face on the whole photo, or around the ticked people in a group picture: close-up,
  shoulders and waist, at 4:5 or Original for one person and Original or 16:9 for a group (picked in the same bar), with the eyes on the upper third and room on the side the face
  is turned to. The one under the pointer tints what it would cut; a click picks it, and Apply (Return) crops the
  photo while Dismiss (Esc) lets it go.
- **Face white balance.** Portrait › Light › White balance sets the photo's Temperature and Tint so the face looks as
  in daylight, taking the light's cast out of the whole picture.
- **Dust spots.** Finds sensor dust spots and removes them; Visualize Spots makes the spots easy to see. Dodge/Burn evens their tone instead of healing them, lifting each spot's own shadow pixel by pixel to its surroundings, so a roughly placed circle leaves the clean pixels in it alone.
- **Copy and sync edits.** Copy all edits, only the changed ones, or a chosen set, and paste or sync them to other
  photos.
- **Print Proof.** Soft-proofs the photo with a printer profile. Hover over **Gamut** or **Below black** to preview
  red out-of-gamut or blue shadow warnings; click either to keep its overlay visible.

## Masks

- **Selections.** Subject, background, sky, object (outlined under the pointer, click to select), scene (vegetation, water, buildings and more)
  and depth. They are computed on this Mac.
- **People.** Choose a person, then the entire person or any of their facial skin, body skin, eyebrows, eye sclera,
  iris and pupil, lips, teeth, hair and clothes; the mask keeps to that person. Skin, hair and clothes come from the People
  model and the face's features from the Face model, both built in. The ticked
  parts and the one under the pointer are tinted on the photo before the mask is made. Scene and People are chosen in
  a card in the Masks panel.
- **Mask list.** Each mask and component shows a small picture of what it selects; Show Overlay tints the selected
  mask on the photo.
- **Shapes.** Brush, linear and radial gradients, color range.
- **Combining.** Add, subtract and intersect up to 32 components per mask, each with its own feather and inversion.
  Each mask takes the same adjustments as the whole photo.

## Tools

Merges add their result to the catalog. If the first source is referenced from a writable local folder, the result goes beside it.
For other sources, including those on network shares, it goes into catalog originals. RAW merges normally produce a linear DNG. Oversized Pixel Shift results are saved as TIFF or JPEG. Merges of
HEIC, JPEG, TIFF or PNG photos (Merge to HDR, Focus Stack, Stack, Merge Best Faces and the Night Sky tools) keep the
photos' own format, color space and HDR gain map, or with **Merge to TIFF** (**Stack to TIFF**) are a 16-bit TIFF, and
take the photo's edits as they are. Each source's Remove
strokes (dust, AI fills, objects, people, face spots) are burnt into the result in Merge to Panorama, Merge to HDR,
Focus Stack, Stack, Merge Best Faces and Wide-Angle Faces; the photos are aligned as shot.

- **Job progress.** Merges, AI Noise Reduction, Wide-Angle Faces and Convert Negative show each running job as a progress bar above the grid, with a button to abort it. The finished photo joins the grid where it sorts. AI Noise Reduction and Wide-Angle Faces work on one photo at a time, as each needs its own check in the tool.
- **Latent images.** Named after the invisible picture on exposed film that only developing brings out, a latent
  image is a catalog item holding a tool's work on its source photos (settings, chosen lines and what analysis found)
  but no pixels of its own; **Merge** or **Render Video…** develops it into a photo or video, and it stays for the
  next version. Tick **Keep Latent Image** to keep one (in Creative Filters' Export dialog, otherwise among the
  tool's options; each tool remembers it). The Night Sky tools then save one as you work, and reopening it skips
  finding and aligning the stars again; the other tools leave one with their first output and update it from then
  on. Merge to Panorama keeps
  its alignment (a source changed since aligns again), Focus Stack its layer brush, Timelapse its framing, timing and
  photos left out, and Creative Filters one per photo with its stack.
  Double-click one to pick up where you left off. They browse like photos, in the grid and in Develop's filmstrip;
  Develop shows the picture the tool last saved, with no editing panels, and **Open in** its tool. Latent images exist only in the catalog,
  never as files, and can't be opened once a source photo is missing; a Night Sky one also not once a source has
  changed.
- **Merge to Panorama.** Aligns and blends overlapping frames, with a cylindrical, spherical or perspective projection.
  When the frames are brackets, HDR turns on and each position's bracket is merged to HDR before stitching, with
  its own Deghost setting. The result is a DNG, so a panorama larger than macOS can develop as a DNG opens blank.
- **Merge to HDR.** Aligns bracketed exposures and merges them in linear light. Moving areas come from the reference exposure.
- **Focus Stack.** Aligns frames focused at different distances and takes each area from its sharpest frame. A layer
  map shows where each frame is used, and a brush overrides it.
- **Merge Pixel Shift.** Combines a camera's pixel shift set into one higher-resolution, lower-noise image: 4 or 16
  Sony ARWs, one Pentax K-1, K-1 Mark II or K-3 Mark III photo taken with Pixel Shift Resolution, a Fujifilm GFX100's
  16 RAFs, or one Hasselblad H6D-400c MS six-shot FFF. A camera's own JPEGs selected with the set are left out. For a
  merge larger than macOS can develop as a DNG, only TIFF and JPEG are offered, and they don't take the first photo's
  edits. A Hasselblad six-shot FFF can be past macOS's size limit for RAW files, so it has no preview and can't be
  developed, yet Merge Pixel Shift can still make a usable TIFF or JPEG from it.
- **Merge Best Faces.** From a few frames of the same group, finds the one where everyone's eyes are open, facing the
  camera and sharp; when none is, it puts each person's best face from another frame into a base frame, chosen in the
  filmstrip. Every person's face in every frame is beside the result to choose from, and a swap that would show (a head
  that moved or turned, hair, hands or a neighbour that moved, different light) is marked. The result takes the base
  photo's edits; a merge that swaps no face asks first. Photos that don't show the same group in the
  same places aren't merged.
- **Night Sky.** Create Star Trails, Night Sky Noise Reduction (averages the sky aligned to the stars) and Composite
  Meteor Shower. With Output set to Video, Star Trails makes a video of the trails building up instead, its options
  and frame in the window and the filmstrip as its timeline; meteors can stay or hold and then fade out, timed in
  seconds or frames. Output set to Live Photo fits that build-up into 3 seconds, ending on the finished trails as the
  still at the chosen size, and adds it to Photos. Star Trails and Meteor Shower list the meteors and aircraft found, each aircraft as one row
  across its photos, to choose which stay in the result. Sky Mask tints the sky and brings up tools to paint it in or
  out or treat the whole frame as sky. Meteor Shower matches the sky around each meteor to the base, keeping changes
  in horizon glow or sky colour from appearing as bright strips around the meteors.
- **Stack.** Blends a sequence by median, mean, clipped mean, lighten or darken: removing people, smoothing water,
  light painting or action sequences.
- **Timelapse.** Create Timelapse Video renders a sequence with framing and timing; optional Sky Noise Reduction on
  macOS aligns nearby starry skies and requires the Sky model. Stabilize, for tripod series and Live Photos, holds the
  view still by moving each photo back by the drift measured on the land, cropping slightly to cover it; frames that
  moved more than 5 % or rolled more than 1° are flagged Not stabilized, and a sky without land is left as it is.
  Timelapse Deflicker smooths exposure changes across the frames.
- **Live Photo.** Create Live Photo opens the Timelapse window with Output set to Live Photo: the photos play with
  its framing, frame rate and timing at Small, iPhone or Large size, Make Key Photo above the frames picks the still, and Bounce
  plays them forward and back; when it runs far from 3 seconds, a button sets the frame rate that fits. The Live Photo is added to Photos.
- **Wide-Angle Faces.** Undoes the stretch a lens 35 mm or wider gives people at the sides of a group shot: heads, and
  with **Bodies** their bodies, take their true shape while the background keeps straight lines. It opens on one selected photo. A tag over each person
  corrects them or leaves them as shot, and a click on a missed head adds it. A pinch zooms the preview and scrolling pans
  it, both photos together in Side by Side. **Lens** takes the 35 mm equivalent focal length from the EXIF, or one typed
  in when the EXIF lacks it or is wrong; Correct waits for one. The copy follows the same destination rules as merges. It is a DNG for
  a RAW; for other photos **Format** Original keeps HEIC, JPEG, TIFF or PNG (HDR gain map included) and saves rarer
  formats such as AVIF as HEIC, or TIFF saves a 16-bit TIFF.
- **Convert Negative.** Inverts film scans using the film base, splits a roll by base when they differ, and balances
  each frame.
- **Creative Filters.** A stack of output filters applied in order: glow, diffusion, bloom, bokeh, polarizer, AI noise
  reduction, pro contrast, tonal contrast, detail extractor, bleach bypass, cross processing, darken and lighten
  center, fog, reflector, light leak, dust and scratches, border and output sharpening. Diffusion's Type picks a
  spread measured from real soft-focus and diffuser filters, or Custom. Glow's Style is Halo (a soft ring round each
  light), Mist (highlights soften and veil), Halation (a red film fringe), Motion (shutter drag along an angle) or
  Streak (thin lines from point lights along an angle); Motion and Streak are turned on the picture. **Export…** opens the Export dialog for the
  filtered photos.
- **Chart Profile.** Builds a camera profile from a photo of a color chart, for the light it was shot in.
- **Match Series.** Matches exposure and color across a series to a reference photo.
- **ID Photo.** Crops and checks portraits against passport, visa and ID photo rules, then exports single
  photos within upload limits or print sheets.

## Output

- **Export.** JPEG, PNG, TIFF, HEIF, AVIF, WebP and JPEG XL. Bit depth and HDR options depend on the format, including 10-bit HEIF and AVIF and 32-bit linear HDR TIFF. Resize, color profile,
  metadata, GPS, watermark and AI noise reduction at the output size. Settings can be saved as presets. GPS is the
  location the catalog has for the photo, so one set or removed in Ceviche is what the file carries.
- **Print.** **File › Print** (⌘P) prints the open photo or library selection at full size, independently of export
  settings; Creative Filters also has a **Print…** button for the filtered photos.
- **Share and Edit In.** Share through macOS or open a photo in another app with Edit In; the edited copy comes back
  into the catalog.
- **XMP.** XMP sidecars written by other raw editors are read on import; Import XMP and Export XMP move edits both ways.
  Photo › Strip Unsupported XMP Settings forgets the imported settings Ceviche doesn’t apply, so their warning stops;
  the edits and the sidecar file are kept.

## iPad and iPhone

The touch app shares the Mac app's catalog format, edit model and rendering, so a photo developed on one looks the
same on the other. Features that belong to the Mac's shell (Folders, Edit In, the command line, MCP, printing) and Merge
Pixel Shift, whose memory an iPad can't spare, are not there, and a merge is offered only when the photos chosen fit the device's memory.

- **Library.** One catalog on the device. Import copies photos in from Files (files or folders) or from Photos, RAW
  included, and they show as they land. The sidebar has Library, Picks, Map and People, then Albums and Utilities,
  which fold: Duplicates (each photo beside its copies, found by background analysis), Archived once something is
  in it, Trash and Storage. Years, Months and All Photos at the foot of the photos lay them out in time: a year or
  month shows as its first photo with its name and count, and a tap shows its photos. The
  filter menu narrows by rating, flag and label and sets the sort, and search covers text, keywords, automatic tags
  and EXIF, offering popular tags while the field is empty and matching tags while typing, as on the Mac. Photos lie in rows at their own shapes; a pinch changes their size. Touch and hold a photo for its
  actions, or Select to work on several: Pick, Reject, Rating, Merge, Tools, Export, and More for labels, albums, Group,
  Paste Edits, Set Location… and Trash (a folded group's photos all go, an expanded group's only those chosen; a touch on a group's corner badge folds or unfolds it); in the Trash the bar has Put Back and Delete (which asks first) and no rating filter, in the archive
  Unarchive, Export and Move to Trash, and selecting ends once the photos have left. The version and Open Source Licenses are under Ceviche in the system's
  Settings. With a keyboard, Shift-tap selects the run from the last photo tapped and Command-tap adds or removes one;
  ⌘A selects all, Esc ends selecting, P, X and U flag, 0 to 5 rate, ⌘G groups, ⌘E exports and ⌘⌫ moves to the Trash.
  In Develop, ⌘Z and ⇧⌘Z undo and redo, the arrows step through the photos, ⇧⌘C and ⇧⌘V copy and paste edits,
  \\ shows the original, ⌘1 to ⌘9 open the tools and Esc goes back. On an iPhone the photos come first and the collections are a step back.
- **People and Map.** People shows a card per person, named first, then Ungrouped; a tap opens their photos, whose
  title names, renames or lists their faces, and touch and hold names, merges or ungroups. Map gathers geotagged
  photos into pins; a pin lists its photos below the map and Show Photos opens them under the place's name.
  Set Location… places photos by a search, typed coordinates or touch and hold on the map, or removes their location.
- **Develop.** The photo fills the screen, with the tools in the bar along the top: Looks, Light, Color, Detail,
  Darkroom, Retouch, Portrait, Masks and Crop. A tool's controls open in a panel that floats over the photo's edge in Liquid Glass, like
  the bar, the histogram and the filmstrip (not on an iPhone, whose screen is too small: upright the tools sit below the photo, which moves up above the open panel, and on its side they are docked in a column at the right, with the chosen scope across the top of Light, and no filmstrip), in cards that fold;
  the lit tool, touched again, closes the panel, and a tap on the photo hides everything. On an iPad the photo is centred
  in the whole screen and stays where it is as panels open and close; zoomed in, it runs under the status bar. The Tools button in the bar opens the tools that work on one photo on the photo being developed. An iPhone's bar keeps the original, Export and More; Undo, Redo and Info sit in a row at the top of More, with Tools and Scope as submenus and Copy, Paste and Reset Edits in a row. More › Move to Trash… (⌘⌫) asks first, then shows the next photo. Shaking the device offers to undo the last edit or Move to Trash, whichever came last; in the Library it puts back the photos last moved to the Trash. On an iPad the panel's grabber drags it to the
  other side and the scope card can be dragged to any corner, as Photos moves its Info. The card in the corner shows one
  scope at a time, Histogram, Waveform, Parade or Vectorscope: a tap moves to the next, More › Scope chooses or turns it off. The
  tone curve's channels are drawn in their own colours and chosen by coloured dots. The bar also has the
  original while held, undo and redo, Info (flags, stars, title, caption, keywords and the photo's details, floating
  where the tool's panel does), Export and More.
  Sliders move by how far the finger travels, finer with the finger pulled away from the track, and a double tap
  puts one back. Looks lists the built-in presets by category, Ceviche's own and the open-source film packs, each
  shown on the photo. Light has Color or B&W, Auto, the tone curve and HDR; Color has white balance with a picker for
  RAW photos, the Color Mixer (the B&W mixer in black and white) and Color grading, a wheel for shadows, midtones, highlights or the whole photo; Detail has
  Presence, Optics and Grain, and Darkroom shows every film stock as a small print of the photo, by kind, and prints
  the photo through the one touched, with its Develop, Print and Texture controls. A pinch or double tap zooms, and past the preview's pixels the part in view is developed from the file.
  The eyedroppers beside white balance and the Color Mixer show a loupe while the finger is on the photo and pick
  where it lifts: a neutral spot, averaged over the square in the loupe, sets Temperature and Tint, a color picks its band, which a vertical drag on the
  photo then moves by Hue, Saturation or Luminance; touched again, an eyedropper is put down.
  Hold the half-filled circle to see the photo as it opened. The menu has Filmstrip, Histogram, Info, History and
  Snapshots, Copy Edits and Paste Edits, Export and Reset Edits; Info holds the flag and stars with the title,
  caption and keywords.
- **Masks.** Subject, Background, People, Brush, Linear gradient, Radial gradient and Color range, and Sky, Depth and
  Scene once their models are installed in Storage. A gradient is drawn with a drag and changed by its handles; the
  brush paints with one finger or Apple Pencil while two fingers move and zoom the photo. Each mask has the
  adjustments it has on the Mac, Feather, Invert, and Add, Subtract and Intersect parts; Show Overlay tints it. People is chosen in the panel, as on the Mac: a person, then Entire Person or their parts, each ticked part tinted on the photo before Create. Once the photo has a mask, a Target menu at the top of Light, Color and Detail
  chooses Global or a mask, and the panel's sliders, tone curve, mixers and grading then edit that mask, as on the Mac.
- **Retouch.** Remove, Heal and Clone brushes painted with one finger or Apple Pencil, two fingers moving and
  zooming the photo; Clone's source is dragged where it should read from, and the strokes are listed to delete one or
  clear all. Select shows the hand-drawn strokes and face spots on the photo: a tap selects one and a drag on bare
  photo boxes several, to hide, show or delete together; the Face spots row opens it with them selected. In Remove a tap outlines the object or wire under it, and Remove or a second tap takes it out. Find Dust
  marks sensor dust as circles: a tap selects one and a drag on bare photo boxes several, to heal, Dodge/Burn or
  remove just those; a tap on bare photo adds a spot. People finds everyone but the subject and outlines them; a tap keeps
  one, Remove takes the rest (offered where the photo fits the device's memory). With its model installed in Storage,
  AI fill fills Remove strokes; without it Remove fills from the surroundings.
- **Portrait.** The photo's faces are tagged on it and listed in the panel; a tap chooses one person, or the main
  people. Even tone (with its model installed in Storage), Reduce shine, White balance, Teeth, Eye whites, Red eye, Lips and Brows are measured for them by Auto and then
  set with a slider, Find blemishes (with its model installed) heals the spots on their faces at a chosen Sensitivity,
  listed as Face spots in Retouch, Reshape has the Mac's Face Liquify sliders, and Reframe crops to Close-up, Shoulders or Waist.
- **Crop.** Drag a corner or the crop itself over the whole photo; aspect presets, Straighten, rotate, flip and Swap.
  Upright corrects by Auto, Level, Vertical or Full from an analysis of the photo, or by Guided: Draw shows the
  photo uncorrected, and up to four guides are dragged along edges that should be vertical or level. Transform has
  the manual perspective, rotation, aspect, scale and offsets, and Constrain Crop keeps the crop inside the corrected photo.
- **Culling.** The Culling menu has Review, a full-screen pass through the photos shown or selected with Pick,
  Reject, Unflag and stars under the thumb, a swipe sideways to move, up to pick and down to reject, and Auto
  Advance; Find Flawed Photos, which lists the suspects by problem to untick before rejecting them; Pick from Bursts,
  which picks the best of each burst or sets it to Group or Skip; Check Faces, each series' faces person by person
  and frame under frame, or a card of faces per photo, where a face zooms the photo to it at actual pixels; Tidy RAW +
  JPEG Pairs, one suggested decision per shot (Archive JPEG, Keep JPEG, Keep RAW, Reject Both) changed pair by pair
  or for a selection; and Move Rejected Photos to Trash. As on the Mac, they set only flags and groups, and Tidy's
  archived JPEGs go to Archived, where Unarchive puts them back.
- **Merges.** From a selection: Merge to HDR, Focus Stack, Stack, Merge to Panorama (bracketed panoramas included),
  Create Star Trails, Night Sky Noise Reduction and Composite Meteor Shower, each with a preview
  and its main options in the inspector beside it (a sheet on an iPhone). As on the Mac, each photo's retouching is
  burnt in, the preview shows the result with the base photo's edits and the result takes them; HDR, Focus Stack and
  Stack show the photos in a strip, where a tap makes one the base. Merges, tools and culling screens share
  Photos' editing bar: close at one end, the screen's name and progress in the middle, its action at the other. Create Star Trails' Output can also be Video or Live Photo, the trails building up frame by
  frame with the Mac's Trails, Glow and Meteors options and the frame set on the preview; a video's Export… opens a
  sheet with Encoder, Container, Color and Quality, then Save or Share, which starts it. The three
  night-sky merges are laid out like the editor in Photos: a rail of modes at the side (Objects, Sky, Photos,
  Options), undo and redo and Outlines in the bar with what the result is made of, and As Captured for meteors.
  Objects lists the lines found as the Mac does, with kept and left-out counts, All, Aircraft or Meteors, and an
  aircraft's pieces under it; Sky has Sky Edge, Add to Sky, Remove from Sky, Use Photo Here, Everything Is Sky and
  Revert to Detected on a dial over the photo; Photos shows each photo's time with Base and a check that leaves it
  out. The result is written as the Mac app writes it and added to the catalog; progress shows in
  the ring in the toolbar, where a merge can be stopped. A merge that would not fit in the memory the device gives
  the app says so instead of starting. Where iOS gives the app less than 8 GB, as on an iPhone, a merge takes a short
  series: up to 5 photos for HDR, 12 for a panorama, 15 for a focus stack and 30 for a stack or a night-sky merge.
- **Tools.** Merge Best Faces sits with the merges and adds its result to the catalog. The Tools menu has Convert
  Negative, each scan inverted with its frame found, film, film base, orientation and roll balance as on the Mac, saved
  as new positives in the catalog; Create Timelapse Video, a frame previewed at the video's framing, size, rate and
  pace with Stabilize and Deflicker, then Export…, a sheet with the encoding and Save or Share, which
  writes it as a job and adds it to Photos or opens the share sheet when done; Create Live Photo, the same screen with Output set to Live
  Photo, which fits the frames into about 3 seconds at a size preset with a key photo as the still and adds it to
  Photos; and Creative Filters, the Mac's filter stack on the photo,
  applied by Export (AI Noise Reduction and Polarizer appear once their models are installed). AI Noise Reduction
  shows a part of a RAW at full size at its white balance and Exposure from Develop, Before and After either side of
  a divider, with Strength, and adds a denoised DNG of each photo to the catalog, its white balance developed in and
  its other edits carried over; the Mac's dialog works the same way. Started from Develop, it closes Develop, so the
  job's progress and then the copy show in the Library. Wide-Angle Faces shows
  the photo corrected with a tag over each person to tap, Add for a missed head and the Mac's Lens, Strength, Bodies
  and Straight Lines, and adds the copy to the catalog with the photo's edits; it and AI Noise Reduction open on one photo. Match Series shows the reference beside
  the photo chosen in the strip and applies the matched Exposure and White Balance as edits. ID Photo frames one
  portrait to a document picked from a searchable list, by country, from the face it finds: a pinch on the print sets
  the head's size and a drag its height within the document's limits, Head › Adjust shows the photo with the print's
  frame, the document's allowed bands and the crown, chin and eye markers to drag, as on the Mac, and Auto puts back what was found, the checks not met are listed with Fit, Auto
  and Replace where the tool can fix them, and Save adds the photo at the document's upload size to Photos and
  closes the tool, a toast saying when it is there; Share beside it hands the same file to the share sheet. Each refuses photos
  that would not fit the device's memory.
- **Export.** JPEG, HEIF, AVIF, TIFF, PNG, WebP and JPEG XL with quality, color space and size, and for photos developed in HDR, HDR or SDR with the Mac's HDR encodings (an SDR photo in the batch goes out in SDR), then Save, which closes
  the sheet and adds the files to Photos as a job (in Develop a ring stands in Export's place meanwhile), a toast saying when they are there, or Share beside it, the share
  sheet for AirDrop, Files and other apps. A video's export sheet has the same Share and Save. Watermark stamps one watermark, a line of text or an image with transparency
  from Files, in one of nine places with its Size and Opacity, set on the photo being exported: a tap places it, a
  pinch sizes it.
- **Storage.** Storage, under Utilities in the sidebar, shows the space the catalog's photos, previews and cache take, with Clear Cache for the decoded RAWs, then lists the models the touch app uses, each with its size and state; a tap downloads one
  from the pinned model set or adds it from a file, and Remove deletes it. The features that need it turn on as soon
  as it is installed. The face models are built in.

## Automation

- **Command line.** Create or open a catalog and import into it at launch; `Ceviche --help` lists the options.
- **MCP.** AI clients can browse the library, read and apply edits and export through a local MCP server, turned on
  in Settings › MCP. Long imports and exports can run as background jobs that the client follows. For work across many
  photos, such as placing old scans on the map or culling, a client looks at up to 50 thumbnails or one contact sheet
  per call and writes ratings, review, labels, keywords and locations to up to 500 photos at once; each batch is one
  step in Edit › Undo, and the locations it writes are marked Set in Ceviche. A client can ask which photos are
  selected and act on those. With read-only access it can still propose edits and metadata changes as dry runs.
  Exports leave GPS out unless the client asks for it. Clients send the token shown there; the bundled `ceviche-mcp` reads it from
  `~/Library/Application Support/Ceviche/mcp-token`.

## Models

- **Models.** The face models behind People and People masks are built in. Depth, scene and sky masks, AI noise
  reduction, AI fill, Find blemishes and Even tone download their models in Settings › Models in the community build. The pinned model set provides one download per model.
