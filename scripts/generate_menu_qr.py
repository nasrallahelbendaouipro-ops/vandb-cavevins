import qrcode

url = "https://vandb-cavevins.netlify.app/menu.html"

img = qrcode.make(url, box_size=20, border=4)
img.save("menu-qr-code.png")
print(f"Saved menu-qr-code.png for {url}, size={img.size}")
