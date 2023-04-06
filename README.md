- IPSW: https://ipsw.me/product/Mac
- Apple Configurator 2: https://apps.apple.com/us/app/apple-configurator-2/id1037126344

---
## I. CÀI LẠI MACOS BẰNG IPSW

a. Tắt nguồn MacBook, bấm giữ nút nguồn để vào Recovery

b. Mở công cụ Disk Utility, xoá Macintosh HD

c. Khởi động lại, kết nối mạng để Activate Mac.

d. Cắm dây C ở cổng đầu tiên của MacBook vào máy Mac còn lại, sau đó tắt nguồn MacBook

d. Giữ tổ hợp phím Control (L) + Option (L) + Shift (R) + Nguồn trong 10 giây

e. Thả tay ở các phím khác, nhưng vẫn tiếp tục giữ phím Nguồn thêm 10 giây

f. MacBook được đưa về DFU, mở Apple Configurator 2 trên máy Mac còn lại và kéo thả file IPSW vào

g. Sau khoảng 10 phút, quá trình cài đặt thành công, MacBook sẽ khởi động lại vào macOS

---
## II. BYPASS KẾT NỐI MẠNG TRONG SETUP ASSISTANT CỦA MACOS VENTURA

a. Tắt nguồn MacBook, bấm giữ nút nguồn để vào Recovery

b. Mở công cụ Terminal, gõ lệnh sau để kích hoạt tài khoản root và đặt mật khẩu cho tài khoản root:
```
dscl -f /Volumes/Data/private/var/db/dslocal/nodes/Default localhost -passwd /Local/Default/Users/root
```
Nhập mật khẩu cho tài khoản root (cần đáp ứng các tiêu chí về độ bảo mật, khác với mật khẩu tài khoản người dùng).

c. Khởi động lại MacBook, thao tác các bước cài đặt ngôn ngữ, khu vực... đến phần kết nối Wi-Fi thì dừng lại (không nhập mật khẩu Wi-Fi).

d. Nhấn cùng lúc 4 phím Command + Option + Control + T để mở Terminal

e. Chọn logo Táo ở góc phía trên bên trái màn hình, chọn System Settings -> User & Groups -> Add Account.

f. macOS sẽ yêu cầu xác thực người dùng, nhập user là root và password là mật khẩu mà bạn đã tạo trước đó.

g. Tạo tài khoản người dùng mới cho macOS, mục New Account nên để là Administrator.

h. Sau khi tạo xong tài khoản, tắt nguồn MacBook rồi giữ nút nguồn để vào Recovery.

i. Mở công cụ Terminal, gõ lệnh sau và nhấn enter:
```
touch /Volumes/Data/private/var/db/.AppleSetupDone
```

k. Khởi động lại MacBook, sau đó đăng nhập vào tài khoản người dùng vừa tạo là xong.

- Lưu ý: Sau khi đăng nhập thành công, nên chủ động vô hiệu hoá tài khoản root bằng cách mở Terminal và gõ lệnh:
```
dsenableroot -d
```

---
## III. CHẶN THÔNG BÁO DEP CHO MACBOOK MDM

a. Hoàn tất trình cài đặt ban đầu, không kết nối vào Wi-Fi khi thiết lập

b. Mở phần mềm Terminal, sau đó thực thi với tài khoản root bằng cách gõ:
```
sudo -i
```

c. Tiếp tục gõ các lệnh sau để chặn host:
```
echo "0.0.0.0 iprofiles.apple.com" >> /etc/hosts
echo "0.0.0.0 mdmenrollment.apple.com" >> /etc/hosts
echo "0.0.0.0 deviceenrollment.apple.com" >> /etc/hosts
```

d. Kiểm tra lại xem file hosts đã thay đổi hay chưa:
```
cat /etc/hosts
```

e. Khởi động lại máy, kết nối Wi-Fi và sử dụng như bình thường

---
## IV. UPDATE OTA CHO MACBOOK MDM

a. Truy cập System Preferences -> Software Update để kiểm tra cập nhật

b. Tải xuống bản cập nhật

c. Ngắt kết nối mạng (forget Wi-Fi, tắt AP, chặn địa chỉ MAC trên router...), sau đó chọn Reboot

d. Sau khi cập nhật hoàn tất, MacBook sẽ khởi động lại vào màn hình Setup

e. Không kết nối mạng, nếu máy yêu cầu nhập mật khẩu iCloud thì chọn Set Up Later

f. Sau khi vào được màn hình chính của macOS, mở Terminal và gõ lệnh sau để check lại file host:
```
cat /etc/hosts
```

g. Nếu file hosts bị khôi phục về mặc định, chặn lại bằng lệnh:
```
echo "0.0.0.0 iprofiles.apple.com" >> /etc/hosts
echo "0.0.0.0 mdmenrollment.apple.com" >> /etc/hosts
echo "0.0.0.0 deviceenrollment.apple.com" >> /etc/hosts
```

h. Kết nối Wi-Fi và sử dụng như bình thường
