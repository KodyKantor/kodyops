package main

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"net/http"
	"os"
)

var (
	ipFile         = "./public_ip.txt"
	configFile     = "./dyndns.conf"
	publicIpUrl    = "https://domains.google.com/checkip"
	publicIpFormat = "text" // supported option for some providers.
	dynDnsUrl      = "https://%s:%s@domains.google.com/nic/update?hostname=%s&myip=%s"
)

type Config struct {
	Username string
	Password string
	FQDN     string
}

// getPublicIp retrieves this host's public IP address.
func getPublicIp() (string, error) {

	resp, err := http.Get(fmt.Sprintf("%s?format=%s", publicIpUrl, publicIpFormat))
	if err != nil {
		return "", fmt.Errorf("error getting public IP: %v", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%s responded with non-200 error code: %d", publicIpUrl, resp.Status)
	}

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("error reading %s response body: %v", publicIpUrl, err)
	}

	publicIp := string(body)

	return publicIp, nil
}

// readIpFromFile reads and returns the previously recorded public IP address.
func readIpFromFile() (string, error) {
	ip, err := os.ReadFile(ipFile)
	// Don't print an error if no previous IP address was recorded.
	if err != nil && !os.IsNotExist(err) {
		return "", fmt.Errorf("error reading ip file '%s': %v", ipFile, err)
	}
	return string(ip), nil
}

// writeIpToFile stores the given IP on the local filesystem so it can be
// referenced later.
func writeIpToFile(ip string) error {
	err := os.WriteFile(ipFile, []byte(ip), 0666)
	if err != nil {
		return fmt.Errorf("error writing ip to file '%s': %v", ipFile, err)
	}
	return nil
}

// updateDynDns sends a request to the dynamic dns provider to update its record
// for this host.
func updateDynDns(config *Config, ip string) error {
	url := fmt.Sprintf(dynDnsUrl, config.Username, config.Password, config.FQDN, ip)

	fmt.Println("request url:", url)

	resp, err := http.Post(url, "", nil)
	if err != nil {
		return fmt.Errorf("error updating Dynamic DNS record: %v", err)
	}

	fmt.Printf("Dyn DNS responded with status code: %d\n", resp.StatusCode)

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("error reading Dyn DNS response body: %v", err)
	}

	fmt.Printf("Dyn DNS response body: %s\n", string(body))

	return nil
}

func grabConfig() (*Config, error) {
	file, err := os.Open(configFile)
	if err != nil {
		return nil, fmt.Errorf("error opening config file '%s': %v", configFile, err)
	}

	decoder := json.NewDecoder(file)
	config := &Config{}
	err = decoder.Decode(config)
	if err != nil {
		return nil, fmt.Errorf("error decoding config file: %v", err)
	}

	return config, nil
}

func main() {
	defer fmt.Println("done")

	fmt.Println("grabbing config")
	config, err := grabConfig()
	if err != nil {
		fmt.Println("could not retrieve config:", err)
		return
	}
	fmt.Println("grabbed config")

	fmt.Println("retrieving public IP address")
	ip, err := getPublicIp()
	if err != nil {
		fmt.Println("could not retrieve public IP:", err)
		return
	}
	fmt.Println("retrieved public IP address:", ip)

	prevIp, err := readIpFromFile()

	if err != nil {
		fmt.Println("could not retrieve previous public IP from file:", err)
		return
	}

	if prevIp == ip {
		fmt.Printf("current public ip and previous public ip are identical: (%s = %s)\n", prevIp, ip)
		return
	}

	fmt.Println("updating Dynamic DNS")
	err = updateDynDns(config, ip)
	if err != nil {
		fmt.Printf("updating dynamic DNS failed: %v", err)
		return
	}
	fmt.Println("updated Dynamic DNS")

	fmt.Println("recording IP address to local file")
	if err = writeIpToFile(ip); err != nil {
		fmt.Println("could not record public IP:", err)
		return
	}
	fmt.Println("recorded IP address to local file")
}
