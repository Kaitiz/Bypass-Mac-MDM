#!/bin/bash

credit() {
    for i in {1..97}
    do
       echo ""
    done
    echo "============================================="
    echo "             MDM Tools by Kaitiz             "
    echo "============================================="
}

show_menu() {
    credit
    echo ""
    echo "1. First Setup (Recovery)"
    echo "2. Disable MDM Notification"
    echo "3. Check MDM Enrollment (Terminal)"
    echo "4. Quit"
    echo ""
}

show_first_setup_menu() {
    for i in {1..97}
    do
       echo ""
    done
    echo "============================================="
    echo "           First Setup (Recovery)            "
    echo "============================================="
    echo ""
    echo "1. Set Root Password (Recovery)"
    echo "2. Apple Setup Done (Recovery)"
    echo "3. Disable Root User (Terminal)"
    echo "4. Back to Main Menu"
    echo ""
}

show_disable_notification_menu() {
    for i in {1..97}
    do
       echo ""
    done
    echo "============================================="
    echo "         MDM Enrollment Notification         "
    echo "============================================="
    echo ""
    echo "1. Disable DEP (Recovery)"
    echo "2. Disable DEP (Terminal - Requires SIP to be disabled)"
    echo "3. Check /etc/hosts file"
    echo "4. Back to Main Menu"
    echo ""
}

handle_choice() {
    case $1 in
        1)
            handle_first_setup
            ;;
        2)
            handle_disable_notification
            ;;
        3)
            for i in {1..97}
            do
               echo ""
            done
            echo "============================================="
            echo "            Check MDM Enrollment             "
            echo "============================================="
            echo ""
            sudo profiles status -type enrollment
            echo ""
            sudo profiles show -type enrollment
            echo ""
            echo "- Note: Error is success -"
            echo ""
            read -p "Please press Enter to continue..."
            ;;
        4)
            echo "Quit. Goodbye!"
            exit 0
            ;;
        *)
            echo "Invalid choice. Please select again."
            ;;
    esac
}

ask_block_hosts() {
    for i in {1..97}
    do
       echo ""
    done
    read -p "Do you want to block hosts? (Y/N): " block_choice
    case $block_choice in
        [Yy]* )
            echo ""
            sudo sed -i '' '/# MDM Servers/d' /Volumes/Macintosh\ HD/etc/hosts
            sudo sed -i '' '/# End/d' /Volumes/Macintosh\ HD/etc/hosts
            sudo sed -i '' '/deviceenrollment.apple.com/d' /Volumes/Macintosh\ HD/etc/hosts
            sudo sed -i '' '/mdmenrollment.apple.com/d' /Volumes/Macintosh\ HD/etc/hosts
            sudo sed -i '' '/iprofiles.apple.com/d' /Volumes/Macintosh\ HD/etc/hosts
            sudo sed -i '' '/acmdm.apple.com/d' /Volumes/Macintosh\ HD/etc/hosts
            sudo sed -i '' '/axm-adm-mdm.apple.com/d' /Volumes/Macintosh\ HD/etc/hosts

            echo "# MDM Servers" | sudo tee -a /Volumes/Macintosh\ HD/etc/hosts
            echo "0.0.0.0 deviceenrollment.apple.com" | sudo tee -a /Volumes/Macintosh\ HD/etc/hosts
            echo "0.0.0.0 mdmenrollment.apple.com" | sudo tee -a /Volumes/Macintosh\ HD/etc/hosts
            echo "0.0.0.0 iprofiles.apple.com" | sudo tee -a /Volumes/Macintosh\ HD/etc/hosts
            echo "0.0.0.0 acmdm.apple.com" | sudo tee -a /Volumes/Macintosh\ HD/etc/hosts
            echo "0.0.0.0 axm-adm-mdm.apple.com" | sudo tee -a /Volumes/Macintosh\ HD/etc/hosts
            echo "# End" | sudo tee -a /Volumes/Macintosh\ HD/etc/hosts

            echo ""
            echo "Blocked all MDM servers!"
            echo ""
            ;;
        [Nn]* )
            echo ""
            echo "Skipping host blocking."
            ;;
        * )
            echo "Invalid choice. Please enter Y or N."
            ask_block_hosts
            ;;
    esac
}

ask_block_hosts_recovery() {
    for i in {1..97}
    do
       echo ""
    done
    read -p "Do you want to block hosts? (Y/N): " block_recovery_choice
    case $block_recovery_choice in
        [Yy]* )
            echo ""
            sed -i '' '/# MDM Servers/d' /Volumes/Macintosh\ HD/etc/hosts
            sed -i '' '/# End/d' /Volumes/Macintosh\ HD/etc/hosts
            sed -i '' '/deviceenrollment.apple.com/d' /Volumes/Macintosh\ HD/etc/hosts
            sed -i '' '/mdmenrollment.apple.com/d' /Volumes/Macintosh\ HD/etc/hosts
            sed -i '' '/iprofiles.apple.com/d' /Volumes/Macintosh\ HD/etc/hosts
            sed -i '' '/acmdm.apple.com/d' /Volumes/Macintosh\ HD/etc/hosts
            sed -i '' '/axm-adm-mdm.apple.com/d' /Volumes/Macintosh\ HD/etc/hosts

            echo "# MDM Servers" >> /Volumes/Macintosh\ HD/etc/hosts
            echo "0.0.0.0 deviceenrollment.apple.com" >> /Volumes/Macintosh\ HD/etc/hosts
            echo "0.0.0.0 mdmenrollment.apple.com" >> /Volumes/Macintosh\ HD/etc/hosts
            echo "0.0.0.0 iprofiles.apple.com" >> /Volumes/Macintosh\ HD/etc/hosts
            echo "0.0.0.0 acmdm.apple.com" >> /Volumes/Macintosh\ HD/etc/hosts
            echo "0.0.0.0 axm-adm-mdm.apple.com" >> /Volumes/Macintosh\ HD/etc/hosts
            echo "# End" >> /Volumes/Macintosh\ HD/etc/hosts

            echo ""
            echo "Blocked all MDM servers!"
            echo ""
            ;;
        [Nn]* )
            echo ""
            echo "Skipping host blocking."
            ;;
        * )
            echo "Invalid choice. Please enter Y or N."
            ask_block_hosts_recovery
            ;;
    esac
}

handle_first_setup() {
    while true; do
        show_first_setup_menu
        read -p "Please choose one option (1-4): " sub_choice
        for i in {1..97}
        do
           echo ""
        done
        case $sub_choice in
            1)
                for i in {1..97}
                do
                   echo ""
                done
                if [ -d "/Volumes/Macintosh HD - Data" ]; then
                    diskutil rename "Macintosh HD - Data" "Data"
                fi
                echo ""
                dscl -f /Volumes/Data/private/var/db/dslocal/nodes/Default localhost -passwd /Local/Default/Users/root
                echo ""
                ask_block_hosts_recovery
                echo ""
                echo "1. Please restart your Mac and select a language..."
                echo "2. Press 'Command + Option + Control + T' at the same time to open Terminal."
                echo "3. In Terminal, go to 'System Settings -> Users & Groups'."
                echo "4. Select 'Add User' and input the username as 'root' and the password as the password you set above."
                echo "5. Create an admin user account, then reboot your Mac to recovery, run the script again, and select 'Apple Setup Done'."
                echo ""
                read -p "Do you want to reboot now? (Y/N): " reboot_choice
                case $reboot_choice in
                    [Yy]* )
                        reboot
                        ;;
                    *)
                        echo "Returning to main menu..."
                        ;;
                esac
                ;;
            2)
                for i in {1..97}
                do
                   echo ""
                done
                if [ -d "/Volumes/Macintosh HD - Data" ]; then
                    diskutil rename "Macintosh HD - Data" "Data"
                fi
                touch /Volumes/Data/private/var/db/.AppleSetupDone
                echo ""
                rm -rf /Volumes/Macintosh\ HD/var/db/ConfigurationProfiles/Settings/.cloudConfigHasActivationRecord
                rm -rf /Volumes/Macintosh\ HD/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound
                touch /Volumes/Macintosh\ HD/var/db/ConfigurationProfiles/Settings/.cloudConfigProfileInstalled
                touch /Volumes/Macintosh\ HD/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound
                ask_block_hosts_recovery
                echo ""
                read -p "Do you want to reboot now? (Y/N): " reboot_choice
                case $reboot_choice in
                    [Yy]* )
                        reboot
                        ;;
                    *)
                        echo "Returning to main menu..."
                        ;;
                esac
                ;;
            3)
                for i in {1..97}
                do
                   echo ""
                done
                dsenableroot -d
                echo ""
                read -p "Please press Enter to continue..."
                ;;
            4)
                echo "Returning to the main menu."
                return
                ;;
            *)
                echo "Invalid choice. Please select again."
                ;;
        esac
    done
}

handle_disable_notification() {
    while true; do
        show_disable_notification_menu
        read -p "Please choose one option (1-4): " noti_choice
        for i in {1..97}
        do
           echo ""
        done
        case $noti_choice in
            1)
                for i in {1..97}
                do
                   echo ""
                done
                rm -rf /Volumes/Macintosh\ HD/var/db/ConfigurationProfiles/Settings/.cloudConfigHasActivationRecord
                rm -rf /Volumes/Macintosh\ HD/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound
                touch /Volumes/Macintosh\ HD/var/db/ConfigurationProfiles/Settings/.cloudConfigProfileInstalled
                touch /Volumes/Macintosh\ HD/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound
                ask_block_hosts_recovery
                echo ""
                read -p "Please press Enter to continue..."
                ;;
            2)
                for i in {1..97}
                do
                   echo ""
                done
                sudo rm /var/db/ConfigurationProfiles/Settings/.cloudConfigHasActivationRecord
                sudo rm /var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound
                sudo touch /var/db/ConfigurationProfiles/Settings/.cloudConfigProfileInstalled
                sudo touch /var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound
                ask_block_hosts
                echo ""
                read -p "Please press Enter to continue..."
                ;;
            3)
                cat /Volumes/Macintosh\ HD/etc/hosts
                echo ""
                read -p "Please press Enter to continue..."
                ;;
            4)
                echo "Returning to the main menu."
                return
                ;;
            *)
                echo "Invalid choice. Please select again."
                ;;
        esac
    done
}

while true; do
    show_menu
    read -p "Please choose one option (1-4): " choice
    handle_choice $choice
done
