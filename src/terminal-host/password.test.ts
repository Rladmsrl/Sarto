import { describe, expect, it } from 'vitest'
import { parseTtyModes, readsPassword } from './password'

// `stty -a` as macOS and Linux print it while sudo reads a password.
const DARWIN = `speed 9600 baud; 24 rows; 80 columns;
lflags: icanon isig iexten -echo echoe -echok echoke -echonl echoctl
	-echoprt -altwerase -noflsh -tostop -flusho pendin -nokerninfo
	-extproc
iflags: -istrip icrnl -inlcr -igncr ixon -ixoff ixany imaxbel iutf8`
const LINUX = `speed 38400 baud; rows 24; columns 80; line = 0;
-parenb -parodd -cmspar cs8 -hupcl -cstopb cread -clocal -crtscts
isig icanon iexten -echo echoe echok -echonl -noflsh -xcase -tostop -echoprt`

describe('reading a password from the modes', () => {
  it('reads echo and canonical input from stty on macOS and Linux', () => {
    expect(parseTtyModes(DARWIN)).toEqual({ echo: false, icanon: true })
    expect(parseTtyModes(LINUX)).toEqual({ echo: false, icanon: true })
    expect(parseTtyModes('lflags: -icanon echo echoe')).toEqual({ echo: true, icanon: false })
    expect(parseTtyModes('echoe echok')).toBeNull()
  })

  it('counts only echo off with canonical input on', () => {
    expect(readsPassword({ echo: false, icanon: true })).toBe(true)
    expect(readsPassword({ echo: false, icanon: false })).toBe(false)
    expect(readsPassword({ echo: true, icanon: true })).toBe(false)
  })
})
