export const MAX_IMAGE_ATTACHMENTS = 4
export const MAX_IMAGE_BYTES = 10 * 1024 * 1024
export const MAX_IMAGE_EDGE = 2048

async function detectedType (file) {
  const bytes = new Uint8Array(await file.slice(0, 12).arrayBuffer())
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg'
  if ([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].every((byte, index) => bytes[index] === byte)) {
    return 'image/png'
  }
  const riff = String.fromCharCode(...bytes.slice(0, 4))
  const webp = String.fromCharCode(...bytes.slice(8, 12))
  return riff === 'RIFF' && webp === 'WEBP' ? 'image/webp' : null
}

function normalizedName (name, type) {
  const stem = name.replace(/\.[^.]+$/, '') || 'image'
  return `${stem}.${type === 'image/png' ? 'png' : 'jpg'}`
}

function canvasBlob (canvas, type, quality) {
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      blob => blob ? resolve(blob) : reject(new Error('The browser could not encode this image.')),
      type,
      quality
    )
  })
}

async function decodeImage (file) {
  if (typeof createImageBitmap === 'function') {
    return createImageBitmap(file, { imageOrientation: 'from-image' })
  }

  const url = URL.createObjectURL(file)
  try {
    const image = new Image()
    image.src = url
    await image.decode()
    return image
  } finally {
    URL.revokeObjectURL(url)
  }
}

function canvasHasAlpha (context, width, height) {
  const pixels = context.getImageData(0, 0, width, height).data
  for (let index = 3; index < pixels.length; index += 4) {
    if (pixels[index] < 255) return true
  }
  return false
}

export function imageSignature (file) {
  return `${file.name}:${file.size}:${file.lastModified}`
}

export async function normalizeImage (file) {
  const sourceType = await detectedType(file)
  if (!sourceType) {
    throw new Error(`${file.name} is not a JPEG, PNG, or WebP image.`)
  }
  if (file.size > MAX_IMAGE_BYTES) {
    throw new Error(`${file.name} is larger than 10 MiB.`)
  }

  let decoded
  try {
    decoded = await decodeImage(file)
    const scale = Math.min(1, MAX_IMAGE_EDGE / Math.max(decoded.width, decoded.height))
    const width = Math.max(1, Math.round(decoded.width * scale))
    const height = Math.max(1, Math.round(decoded.height * scale))
    const canvas = document.createElement('canvas')
    canvas.width = width
    canvas.height = height
    const context = canvas.getContext('2d', { willReadFrequently: sourceType === 'image/webp' })
    if (!context) throw new Error('Canvas image processing is unavailable.')
    context.drawImage(decoded, 0, 0, width, height)

    let outputType = sourceType
    if (sourceType === 'image/webp') {
      outputType = canvasHasAlpha(context, width, height) ? 'image/png' : 'image/jpeg'
    }
    const blob = await canvasBlob(canvas, outputType, outputType === 'image/jpeg' ? 0.9 : undefined)
    if (blob.size > MAX_IMAGE_BYTES) {
      throw new Error(`${file.name} is larger than 10 MiB after normalization.`)
    }

    const normalized = new File(
      [blob],
      normalizedName(file.name, outputType),
      { type: outputType, lastModified: file.lastModified }
    )
    return {
      key: imageSignature(file),
      file: normalized,
      filename: file.name,
      previewUrl: URL.createObjectURL(normalized),
      width,
      height
    }
  } catch (error) {
    throw new Error(`${file.name} could not be decoded or normalized: ${error.message}`)
  } finally {
    decoded?.close?.()
  }
}
