#!/bin/bash

credit() {
    for i in {1..18}
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
    echo "3. Check MDM Enrollment"
    echo "4. Quit"
    echo ""
}

show_first_setup_menu() {
    for i in {1..18}
    do
       echo ""
    done
    echo "============================================="
    echo "           First Setup (Recovery)            "
    echo "============================================="
    echo ""
    echo "1. Set Root Password (Recovery)"
    echo "2. Apple Setup Done (Recovery)"
    echo "3. Disable Root User"
    echo "4. Back to Main Menu"
    echo ""
}

show_disable_notification_menu() {
    for i in {1..18}
    do
       echo ""
    done
    echo "============================================="
    echo "         MDM Enrollment Notification         "
    echo "============================================="
    echo ""
    echo "1. Disable DEP (Recovery)"
    echo "2. Disable DEP (Terminal)"
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
            for i in {1..18}
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
    read -p "Do you want to block hosts? (Y/N): " block_choice
    case $block_choice in
        [Yy]* )
            echo "0.0.0.0 deviceenrollment.apple.com" >>/Volumes/Macintosh\ HD/etc/hosts
            echo "0.0.0.0 mdmenrollment.apple.com" >>/Volumes/Macintosh\ HD/etc/hosts
            echo "0.0.0.0 iprofiles.apple.com" >>/Volumes/Macintosh\ HD/etc/hosts
            ;;
        [Nn]* )
            echo "Skipping host blocking."
            ;;
        * )
            echo "Invalid choice. Please enter Y or N."
            ask_block_hosts
            ;;
    esac
}

handle_first_setup() {
    while true; do
        show_first_setup_menu
        read -p "Please choose one option (1-4): " sub_choice
        for i in {1..18}
        do
           echo ""
        done
        case $sub_choice in
            1)
                for i in {1..18}
                do
                   echo ""
                done
                if [ -d "/Volumes/Macintosh HD - Data" ]; then
                    diskutil rename "Macintosh HD - Data" "Data"
                fi
                echo ""
                dscl -f /Volumes/Data/private/var/db/dslocal/nodes/Default localhost -passwd /Local/Default/Users/root
                echo ""
                ask_block_hosts
                echo ""
                echo "1. Please restart your Mac and select a language..."
                echo "2. Press 'Command + Option + Control + T' at the same time to open Terminal."
                echo "3. In Terminal, go to 'System Settings -> Users & Groups'."
                echo "4. Create an admin user account, then reboot your Mac to recovery, run the script again, and select 'Apple Setup Done'."
                echo ""
                read -p "Please press Enter to continue..."
                ;;
            2)
                for i in {1..18}
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
                echo ""
                read -p "Please press Enter to continue..."
                ;;
            3)
                for i in {1..18}
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
        for i in {1..18}
        do
           echo ""
        done
        case $noti_choice in
            1)
                for i in {1..18}
                do
                   echo ""
                done
                rm -rf /Volumes/Macintosh\ HD/var/db/ConfigurationProfiles/Settings/.cloudConfigHasActivationRecord
                rm -rf /Volumes/Macintosh\ HD/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound
                touch /Volumes/Macintosh\ HD/var/db/ConfigurationProfiles/Settings/.cloudConfigProfileInstalled
                touch /Volumes/Macintosh\ HD/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound
                echo ""
                read -p "Please press Enter to continue..."
                ;;
            2)
                for i in {1..18}
                do
                   echo ""
                done
                sudo rm /var/db/ConfigurationProfiles/Settings/.cloudConfigHasActivationRecord
                sudo rm /var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound
                sudo touch /var/db/ConfigurationProfiles/Settings/.cloudConfigProfileInstalled
                sudo touch /var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound
                echo ""
                read -p "Please press Enter to continue..."
                ;;
            3)
                cat /etc/hosts
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
