import cv2
import shutil
import sys

# The "Density" string. Dark to Light.
# Change this string to change the aesthetic!
# original: CHARS = " .:-=+*#%@"
CHARS = "!@#$%^&*':;.,<>[](){}?=+-_"
    
def frame_to_ascii(frame, width):
    height, original_width = frame.shape
    aspect_ratio = height / original_width
    # Terminals characters are tall, so we correct aspect ratio (0.55)
    new_height = int(width * aspect_ratio * 0.55)
    
    resized = cv2.resize(frame, (width, new_height))
    
    # Map pixels to characters
    ascii_str = ""
    for pixel_value in resized.flatten():
        ascii_str += CHARS[pixel_value // 29] # 255 / 9 chars = ~28
        
    return ascii_str

cap = cv2.VideoCapture(0)

try:
    while True:
        ret, frame = cap.read()
        if not ret: break
        
        # Convert to grayscale
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        
        # Get terminal size
        term_w = shutil.get_terminal_size().columns
        
        # Generate ASCII
        ascii_art = frame_to_ascii(gray, term_w)
        
        # Move cursor to top-left (Magic trick to stop flickering)
        sys.stdout.write("\033[H")
        
        # Print frame. We slice to fit exactly.
        img_len = len(ascii_art)
        
        # Draw line by line
        for i in range(0, img_len, term_w):
            sys.stdout.write(ascii_art[i:i+term_w] + "\n")
            
except KeyboardInterrupt:
    cap.release()
    print("\nDisconnected.")
