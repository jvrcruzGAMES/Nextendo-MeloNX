//
//  AccountManagerView.swift
//  MeloNX
//
//  Created by Stossy11 on 17/07/2025.
//

import SwiftUI

struct AccountManagerView: View {
    @EnvironmentObject var ryujinx: RyujinxController
    @State private var profiles: Profiles? = nil
    @State var test = false
    @State var editAccount = false
    @State private var isSyncingNextendo = false
    @Environment(\.presentationMode) var presentationMode
    let profilePath = URL.documentsDirectory.appendingPathComponent("system").appendingPathComponent("Profiles.json")
    @State var account: Account? = nil
    
    private var nextendoUsername: String {
        NextendoKeychainHelper.loadCredentials()?.username ?? UserDefaults.standard.string(forKey: "nextendoUserPseudo") ?? ""
    }
    private var nextendoPid: String {
        NextendoKeychainHelper.loadCredentials()?.pid ?? UserDefaults.standard.string(forKey: "nextendoPid") ?? "0"
    }
    private var isNextendoConnected: Bool {
        guard let creds = NextendoKeychainHelper.loadCredentials() else {
            let token = UserDefaults.standard.string(forKey: "nextendoAuthToken") ?? ""
            let pid = UserDefaults.standard.string(forKey: "nextendoPid") ?? "0"
            return !token.isEmpty && pid != "0"
        }
        return !creds.token.isEmpty && creds.pid != "0"
    }
    
    private func isNextendoProfile(_ profile: Account) -> Bool {
        guard !nextendoUsername.isEmpty && nextendoPid != "0" else { return false }
        return profile.name.lowercased() == nextendoUsername.lowercased()
    }
    
    var body: some View {
        NavigationStack {
            VStack {
                if let profiles {
                    Form {
                        ForEach(profiles.profiles) { profile in
                            HStack(spacing: 16) {
                                if let data = Data(base64Encoded: profile.image ?? ""), let uiImage = UIImage(data: data) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 48, height: 48)
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(Color.gray, lineWidth: 1))
                                } else {
                                    Image(systemName: "person.crop.circle.fill")
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 48, height: 48)
                                        .foregroundColor(.gray)
                                }
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(profile.name)
                                        .font(.headline)
                                    HStack(spacing: 6) {
                                        if profile.user_id == self.profiles?.last_opened ?? "" {
                                            Text("Current")
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 2)
                                                .font(.caption2)
                                                .background(Color.green.opacity(0.15))
                                                .foregroundColor(.green)
                                                .cornerRadius(6)
                                        }
                                        if isNextendoProfile(profile) {
                                            HStack(spacing: 3) {
                                                Image(systemName: "globe")
                                                    .font(.system(size: 9))
                                                Text("Nextendo")
                                                    .font(.caption2.weight(.medium))
                                            }
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.15))
                                            .foregroundColor(.blue)
                                            .cornerRadius(6)
                                        }
                                        Text("Last modified: \(formattedDate(profile.last_modified_timestamp))")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                    }
                                }
                                Spacer()
                            }
                            .swipeActions(edge: .trailing) {
                                if profile.user_id != "00000000000000010000000000000000" {
                                    Button(role: .destructive) {
                                        var profiles2 = profiles
                                        profiles2.profiles.removeAll { $0.user_id == profile.user_id }
                                        if let cool = profiles2.profiles.first(where: { $0.user_id != profile.user_id }), profiles.last_opened == profile.user_id {
                                            Ryujinx.closeUser(userId: profile.user_id)
                                            Ryujinx.openUser(userId: cool.user_id)
                                            profiles2.last_opened = cool.user_id
                                        } else {
                                            if profiles.last_opened == profile.user_id {
                                                profiles2.last_opened = "00000000000000010000000000000000"
                                            }
                                        }

                                        saveAccounts(profiles2)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                }
                                
                                Button {
                                    account = profile
                                    print(account == nil) // this is required to for the sheet to show, don't ask.
                                    editAccount = true
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                
                                if isNextendoConnected && isNextendoProfile(profile) {
                                    Button {
                                        syncNextendo()
                                    } label: {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                    }
                                    .tint(.blue)
                                }
                            }
                            .onTapGesture {
                                if profiles.profiles.contains(where: { $0.user_id == profiles.last_opened }) {
                                    Ryujinx.closeUser(userId: profiles.last_opened)
                                }
                                Ryujinx.openUser(userId: profile.user_id)
                                initEnvironmentVariables(reloadAccount: true)
                                
                                loadAccounts()
                            }
                        }
                    }
                    .navigationTitle("Profile Manager")
                    .sheet(isPresented: $test, onDismiss: {
                        loadAccounts()
                    }) {
                        CreateAccount()
                    }
                    .sheet(isPresented: $editAccount, onDismiss: {
                        guard let account else { loadAccounts(); return }
                        var profiles2 = profiles
                        guard let index = profiles2.profiles.firstIndex(where: { $0.user_id == account.user_id }) else { loadAccounts(); return }
                        
                        profiles2.profiles[index] = account

                        saveAccounts(profiles2)
                        loadAccounts()
                        self.account = nil
                    }) {
                        EditAccount(account: $account)
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .navigationBarTrailing) {
                            if isNextendoConnected {
                                Button {
                                    syncNextendo()
                                } label: {
                                    if isSyncingNextendo {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                    }
                                }
                                .disabled(isSyncingNextendo)
                            }
                            
                            Button {
                                test = true
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
                    }
                } else {
                    HStack {
                        Text("Loading Accounts...")
                            .font(.title3)
                        
                        ProgressView()
                            .scaleEffect(2.0, anchor: .center)
                    }
                }
            }
        }
        .onAppear() {
            loadAccounts()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NextendoProfileUpdated"))) { _ in
            loadAccounts()
        }
    }
    
    func syncNextendo() {
        isSyncingNextendo = true
        NextendoProfileHelper.shared.syncCurrentSavedAccount { success, _ in
            DispatchQueue.main.async {
                self.isSyncingNextendo = false
                self.loadAccounts()
            }
        }
    }
    
    func loadAccounts() {
        do {
            let data = try Data(contentsOf: profilePath)
            profiles = try JSONDecoder().decode(Profiles.self, from: data)
        } catch {
            print("Failed to load profiles: \(error)")
            presentationMode.wrappedValue.dismiss()
        }
    }

    
    func saveAccounts(_ updatedProfiles: Profiles) {
        do {
            let data = try JSONEncoder().encode(updatedProfiles)
            try data.write(to: profilePath)
            
            Ryujinx.refreshAccountManager()
            loadAccounts()
        } catch {
            print("Failed to save profiles: \(error)")
        }
    }

    private func formattedDate(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
