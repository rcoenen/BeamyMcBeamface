# Roku Playback

## MODIFIED Requirements

### Requirement: Progress bar MUST show accurate Roku playback position

The progress bar MUST display the actual playback position from Roku rather than an estimate.

#### Scenario: User plays video on Roku
- Given a video is playing on Roku
- When the progress bar updates
- Then it shows the actual position from `/query/media-player`
- And the position matches what's displayed on the TV

#### Scenario: Roku buffers or stalls
- Given a video is playing on Roku
- When the Roku buffers or stalls
- Then the progress bar pauses at the correct position
- And resumes accurately when playback continues

#### Scenario: User controls playback via Roku remote
- Given a video is playing on Roku
- When the user pauses via Roku remote
- Then Beamy's UI updates to show paused state
- And the progress bar stops advancing
